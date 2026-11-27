// Harmony patch targets that no longer exist, read out of METADATA ONLY: the mod and every
// reference it compiled against are opened with System.Reflection.Metadata, so not one line
// of game code is loaded or run. Compiled in-process by gate/harmony.ps1 through Add-Type;
// System.Reflection.Metadata ships inside the .NET runtime pwsh itself runs on, so there is
// nothing to restore and nothing to build.
//
// Resolution follows Harmony's own PatchTools.GetOriginalMethod: DeclaredMethod /
// DeclaredPropertyGetter / DeclaredPropertySetter / DeclaredConstructor -- DECLARED members
// only, and a name with no argumentTypes over several overloads is Harmony's "Ambiguous
// match". argumentTypes go to Type.GetMethod with the default binder, so an overload the
// arguments are ASSIGNABLE to matches (a Player for a Unit parameter), not only an exact one.
// ___field parameters go through AccessTools.Field, which does walk base types.
//
// Reflection lookups in IL (AccessTools.Method/Field/Property/TypeByName, "Type:Member",
// FieldRefAccess, Type.GetMethod/GetField/GetProperty) are read with a small symbolic stack:
// only literal types, names and Type[] arguments are checked, everything computed is
// counted as not checkable. A missing member whose result is null-checked (a version probe
// with a fallback) is a warning, not a failure.
using System;
using System.Collections.Generic;
using System.Collections.Immutable;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Reflection.Metadata;
using System.Reflection.Metadata.Ecma335;
using System.Reflection.PortableExecutable;
using System.Text;
using System.Text.RegularExpressions;

public sealed class QGateHarmony : ISignatureTypeProvider<string, object>, ICustomAttributeTypeProvider<string>
{
    // Type names as plain strings: Ns.Outer+Inner, arrays kept, byref dropped, generic
    // arguments dropped (List`1). Both sides of every comparison are built the same way.
    public string GetPrimitiveType(PrimitiveTypeCode c) => "System." + c;
    public string GetTypeFromDefinition(MetadataReader r, TypeDefinitionHandle h, byte k) => Name(r, h);
    public string GetTypeFromReference(MetadataReader r, TypeReferenceHandle h, byte k) => Name(r, h);
    public string GetTypeFromSpecification(MetadataReader r, object c, TypeSpecificationHandle h, byte k) => r.GetTypeSpecification(h).DecodeSignature(this, c);
    public string GetSZArrayType(string e) => e + "[]";
    public string GetArrayType(string e, ArrayShape s) => e + "[" + new string(',', s.Rank - 1) + "]";
    public string GetByReferenceType(string e) => e;
    public string GetPointerType(string e) => e + "*";
    public string GetGenericInstantiation(string g, ImmutableArray<string> a) => g;
    public string GetGenericTypeParameter(object c, int i) => "!" + i;
    public string GetGenericMethodParameter(object c, int i) => "!!" + i;
    public string GetFunctionPointerType(MethodSignature<string> s) => "fnptr";
    public string GetModifiedType(string m, string u, bool req) => u;
    public string GetPinnedType(string e) => e;
    public string GetSystemType() => "System.Type";
    public bool IsSystemType(string t) => t == "System.Type";
    public string GetTypeFromSerializedName(string n) => n;
    // ponytail: only Harmony's own attributes are decoded, and MethodType/ArgumentType are int.
    public PrimitiveTypeCode GetUnderlyingEnumType(string t) => PrimitiveTypeCode.Int32;

    static string Name(MetadataReader r, TypeDefinitionHandle h)
    {
        var t = r.GetTypeDefinition(h);
        var d = t.GetDeclaringType();
        if (!d.IsNil) return Name(r, d) + "+" + r.GetString(t.Name);
        var ns = r.GetString(t.Namespace);
        return ns.Length == 0 ? r.GetString(t.Name) : ns + "." + r.GetString(t.Name);
    }

    static string Name(MetadataReader r, TypeReferenceHandle h)
    {
        var t = r.GetTypeReference(h);
        if (t.ResolutionScope.Kind == HandleKind.TypeReference) return Name(r, (TypeReferenceHandle)t.ResolutionScope) + "+" + r.GetString(t.Name);
        var ns = r.GetString(t.Namespace);
        return ns.Length == 0 ? r.GetString(t.Name) : ns + "." + r.GetString(t.Name);
    }

    // The assembly a type reference points into; null = this one.
    static string Scope(MetadataReader r, TypeReferenceHandle h)
    {
        var t = r.GetTypeReference(h);
        while (t.ResolutionScope.Kind == HandleKind.TypeReference) t = r.GetTypeReference((TypeReferenceHandle)t.ResolutionScope);
        return t.ResolutionScope.Kind == HandleKind.AssemblyReference
            ? r.GetString(r.GetAssemblyReference((AssemblyReferenceHandle)t.ResolutionScope).Name) : null;
    }

    // "System.Collections.Generic.List`1[[System.Int32, mscorlib]], mscorlib" -> "System.Collections.Generic.List`1"
    static string Norm(string s)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == ',') break;
            if (c == '&') continue;
            if (c == '[' && i + 1 < s.Length && s[i + 1] != ']' && s[i + 1] != ',')
            {
                for (int depth = 0; i < s.Length; i++)
                {
                    if (s[i] == '[') depth++;
                    else if (s[i] == ']' && --depth == 0) break;
                }
                continue;
            }
            sb.Append(c);
        }
        return sb.ToString().Trim();
    }

    // "Ns.T, assembly_valheim, Version=..." -> "assembly_valheim"; null when not qualified.
    static string AsmOf(string s)
    {
        int depth = 0;
        for (int i = 0; i < s.Length; i++)
        {
            if (s[i] == '[') depth++;
            else if (s[i] == ']') depth--;
            else if (s[i] == ',' && depth == 0)
            {
                var rest = s.Substring(i + 1);
                int c = rest.IndexOf(',');
                return (c < 0 ? rest : rest.Substring(0, c)).Trim();
            }
        }
        return null;
    }

    // Ref: a reference assembly ([ReferenceAssembly], e.g. the net48 targeting pack's
    // mscorlib) -- public surface only, private members stripped.
    sealed class Asm { public MetadataReader R; public PEReader Pe; public bool Ref; public string Path; }
    sealed class Target { public string Type, Method; public int? Kind; public string[] Args; public bool ByName; public Target Clone() => (Target)MemberwiseClone(); }
    // One value on the symbolic IL stack. K: 'T' a type (S = name, Asm = its assembly),
    // 's' a string, 'i' an int, '0' null, 'a' a Type[] (Arr; a null element is not known).
    // Anything else is a null V.
    // Pend: the finding of a failed lookup whose null is still on its way to a check (Done once
    // judged); Sink: the local/field this value was read from.
    sealed class V { public char K; public string S, Asm; public int N; public string[] Arr; public string Pend, Sink; public bool Done; }
    static V T(string name, string asm = null) => new V { K = 'T', S = name, Asm = asm };

    readonly Dictionary<string, (Asm A, TypeDefinitionHandle H)> types = new();
    Dictionary<string, (Asm A, TypeDefinitionHandle H)> local = new();
    readonly HashSet<string> loaded = new(StringComparer.OrdinalIgnoreCase);
    // Type forwarders (netstandard.dll, facades): a name that lives in some other assembly.
    readonly HashSet<string> forwarded = new(StringComparer.Ordinal);
    Dictionary<string, string> bySimple;
    readonly Dictionary<string, string> source = new();
    Asm mod;
    bool mapped;
    SortedSet<string> fails, probes, refOnly;
    // The type the last HasMember/Overloads looked in is from a reference assembly: a member
    // not found there may be a private one it stripped -- the absence proves nothing.
    bool stripped;
    // -Why / -Targets: every target that DID resolve, so a reviewer can confirm a specific new
    // patch by name instead of inferring it from a count that went up.
    List<string> oks;
    bool listTargets;
    // The reflection lookup Lookup() just resolved; Scan appends the source location.
    string okLookup;
    // Failed lookups whose result was stored (local/field/return): a probe if null-checked where read.
    List<(string Msg, string Sink)> stored;
    List<(string From, string To)> sinkLinks;
    Dictionary<string, List<string>> returnCallSites;
    HashSet<string> escapedReturns, poisonedSinks;
    int callSiteId;
    HashSet<string> checkedSinks;
    int nChecked, nDynamic, nComputed, nUnloaded;

    // mods[0..own) are this repository's assemblies: their findings fail. The rest are other
    // assemblies checked against the same references (qgate.json harmony.assemblies) -- not
    // this repository's code, so everything found there is a warning.
    public static string[] Run(string[] mods, int own, string[] refPaths, string srcDir, string root, bool targets = false)
    {
        var q = new QGateHarmony { listTargets = targets };
        var asms = mods.Select(Load).ToArray();
        foreach (var a in asms) if (a != null) q.Index(a);
        var refs = refPaths.Select(Load).Where(a => a != null).ToList();
        foreach (var a in refs) q.Index(a);
        // A reference assembly the build compiled against (the net48 pack's mscorlib) is not
        // what the game runs: the runtime copy of the same file beside the game's own
        // references (Unity's Managed\mscorlib.dll) is, and it has the private fields
        // FieldRefAccess reaches for. Index that one over the stripped one (#119).
        var dirs = refs.Where(a => !a.Ref).Select(a => System.IO.Path.GetDirectoryName(a.Path)).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        foreach (var a in refs.Where(a => a.Ref))
            foreach (var d in dirs)
            {
                var rt = Load(System.IO.Path.Combine(d, System.IO.Path.GetFileName(a.Path)));
                if (rt != null && !rt.Ref) { q.IndexRuntime(rt, d); break; }
            }
        q.MapSource(srcDir, root);
        var outp = new List<string>();
        const string probe = " -- its result is null-checked: a version probe with a fallback";
        const string refOnlyWhy = " -- only a reference assembly (private members stripped) declares the type, no runtime copy beside the references: not checkable";
        for (int i = 0; i < asms.Length; i++)
        {
            if (asms[i] == null) continue;
            q.Check(asms[i], i < own);
            var file = Path.GetFileName(mods[i]);
            var pre = i < own ? "" : file + ": ";
            outp.AddRange(q.fails.Select(f => i < own ? f : "[WARN] harmony: " + pre + f));
            outp.AddRange(q.probes.Select(p => "[WARN] harmony: " + pre + p + probe));
            outp.AddRange(q.refOnly.Select(p => "[WARN] harmony: " + pre + p + refOnlyWhy));
            outp.AddRange(q.oks.Select(o => "[NOTE] harmony: " + pre + o));
            int skipped = q.nDynamic + q.nComputed + q.nUnloaded;
            if (q.nChecked + skipped == 0) continue;
            var why = new[] { (q.nDynamic, "non-literal lookup(s)"), (q.nComputed, "TargetMethod(s) / no declared target"), (q.nUnloaded, "in assemblies not loaded") }
                .Where(w => w.Item1 > 0).Select(w => $"{w.Item1} {w.Item2}");
            outp.Add($"[NOTE] harmony: {file} -- {q.nChecked} target(s) checked"
                + (skipped > 0 ? $", {skipped} not checkable statically ({string.Join(", ", why)})" : ""));
        }
        return outp.ToArray();
    }

    static Asm Load(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var pe = new PEReader(ImmutableArray.Create(File.ReadAllBytes(path)));
            if (!pe.HasMetadata) return null;
            var r = pe.GetMetadataReader();
            var isRef = r.IsAssembly && r.GetAssemblyDefinition().GetCustomAttributes()
                .Any(h => AttrName(r, r.GetCustomAttribute(h)) == "System.Runtime.CompilerServices.ReferenceAssemblyAttribute");
            return new Asm { Pe = pe, R = r, Ref = isRef, Path = path };
        }
        catch (Exception) { return null; }
    }

    void Index(Asm a)
    {
        var r = a.R;
        if (r.IsAssembly) loaded.Add(r.GetString(r.GetAssemblyDefinition().Name));
        foreach (var h in r.TypeDefinitions)
        {
            var n = Name(r, h);
            // A runtime definition replaces a reference-assembly one; otherwise the first wins.
            if (!types.TryAdd(n, (a, h)) && types[n].A.Ref && !a.Ref) types[n] = (a, h);
        }
        foreach (var h in r.ExportedTypes)
        {
            var e = r.GetExportedType(h);
            var ns = r.GetString(e.Namespace);
            if (e.IsForwarder) forwarded.Add(ns.Length == 0 ? r.GetString(e.Name) : ns + "." + r.GetString(e.Name));
        }
    }

    // A .NET (Core) runtime copy is a facade: System.Collections.dll only type-forwards List`1
    // to System.Private.CoreLib.dll beside it. Index what the forwards point to as well (#187).
    readonly HashSet<string> followed = new(StringComparer.OrdinalIgnoreCase);
    void IndexRuntime(Asm a, string dir)
    {
        Index(a);
        var r = a.R;
        foreach (var h in r.ExportedTypes)
        {
            var e = r.GetExportedType(h);
            if (!e.IsForwarder || e.Implementation.Kind != HandleKind.AssemblyReference) continue;
            var n = r.GetString(r.GetAssemblyReference((AssemblyReferenceHandle)e.Implementation).Name);
            if (!followed.Add(n)) continue;
            var t = Load(System.IO.Path.Combine(dir, n + ".dll"));
            if (t != null && !t.Ref) IndexRuntime(t, dir);
        }
    }

    // The assembly being checked first: plugins embed copies of each other's API classes
    // (EpicLoot ships its own Auga.API), and the first-indexed copy is not the one it calls.
    // ponytail: a type reference into a third assembly still takes the first-indexed copy.
    bool Get(string n, out (Asm A, TypeDefinitionHandle H) x) => local.TryGetValue(n, out x) || types.TryGetValue(n, out x);

    bool Unloaded(string asm, string type) => (asm != null && !loaded.Contains(asm)) || forwarded.Contains(type);

    // typeof(T) resolves by full name; a type NAME (HarmonyPatch("T", "M"), "T:M", TypeByName)
    // goes through AccessTools.TypeByName, whose last fallback is the simple name.
    string FindType(string name, bool byName)
    {
        var n = Norm(name);
        if (Get(n, out _)) return n;
        if (!byName) return null;
        if (bySimple == null)
        {
            bySimple = new();
            foreach (var k in types.Keys) bySimple.TryAdd(k.Substring(Math.Max(k.LastIndexOf('.'), k.LastIndexOf('+')) + 1), k);
        }
        return bySimple.TryGetValue(n, out var full) ? full : null;
    }

    // Patch class -> "file.cs:line", by declaration in the project's sources: Windows PDBs
    // (DebugType full/pdbonly, what these mods ship) are not readable here, and the class
    // is what the reader has to open. A name declared twice maps to nothing, not a guess.
    void MapSource(string srcDir, string root)
    {
        if (srcDir == null || !Directory.Exists(srcDir)) return;
        var decl = new Regex(@"\b(?:class|struct)\s+(\w+)");
        foreach (var f in Directory.EnumerateFiles(srcDir, "*.cs", SearchOption.AllDirectories))
        {
            var rel = Path.GetRelativePath(root, f).Replace('\\', '/');
            if (Regex.IsMatch(rel, @"(^|/)(bin|obj)/")) continue;
            var lines = File.ReadAllLines(f);
            for (int i = 0; i < lines.Length; i++)
                foreach (Match m in decl.Matches(lines[i]))
                {
                    var n = m.Groups[1].Value;
                    source[n] = source.ContainsKey(n) ? null : rel + ":" + (i + 1);
                }
        }
    }

    string Where(string typeName, string method)
    {
        // Lambdas and iterators live in compiler-generated <>c / <Foo>d__3 types: name the
        // user's type that holds them.
        var simple = typeName.Split('+').Where(s => !s.StartsWith("<")).LastOrDefault() ?? typeName;
        simple = simple.Substring(simple.LastIndexOf('.') + 1);
        return mapped && source.TryGetValue(simple, out var loc) && loc != null ? $"({loc}, {simple}.{method})" : $"({typeName}.{method})";
    }

    static string AttrName(MetadataReader r, CustomAttribute ca)
    {
        if (ca.Constructor.Kind == HandleKind.MethodDefinition)
            return Name(r, r.GetMethodDefinition((MethodDefinitionHandle)ca.Constructor).GetDeclaringType());
        if (ca.Constructor.Kind != HandleKind.MemberReference) return "";
        var p = r.GetMemberReference((MemberReferenceHandle)ca.Constructor).Parent;
        return p.Kind == HandleKind.TypeReference ? Name(r, (TypeReferenceHandle)p)
            : p.Kind == HandleKind.TypeDefinition ? Name(r, (TypeDefinitionHandle)p) : "";
    }

    static bool Has(MetadataReader r, CustomAttributeHandleCollection attrs, params string[] names) =>
        attrs.Any(h => names.Contains(AttrName(r, r.GetCustomAttribute(h))));

    void Check(Asm a, bool own)
    {
        mod = a;
        mapped = own; // the sources are this repository's: another assembly's API class is not ours
        local = new();
        foreach (var h in a.R.TypeDefinitions) local.TryAdd(Name(a.R, h), (a, h));
        fails = new(StringComparer.Ordinal);
        probes = new(StringComparer.Ordinal);
        refOnly = new(StringComparer.Ordinal);
        oks = new();
        stored = new();
        sinkLinks = new();
        returnCallSites = new();
        escapedReturns = new(StringComparer.Ordinal);
        poisonedSinks = new(StringComparer.Ordinal);
        callSiteId = 0;
        checkedSinks = new();
        nChecked = nDynamic = nComputed = nUnloaded = 0;
        CheckAttributes();
        guards = PrepareGuards();
        CheckIL();
        bool pgrew = true;
        while (pgrew)
        {
            pgrew = false;
            foreach (var (from, to) in sinkLinks)
                if (poisonedSinks.Contains(to) && poisonedSinks.Add(from)) pgrew = true;
            foreach (var (retKey, sites) in returnCallSites)
                if (sites.Any(s => poisonedSinks.Contains(s)) && poisonedSinks.Add(retKey)) pgrew = true;
        }
        checkedSinks.ExceptWith(poisonedSinks);
        bool grew = true;
        while (grew)
        {
            grew = false;
            foreach (var (from, to) in sinkLinks)
                if (checkedSinks.Contains(to) && !poisonedSinks.Contains(from) && checkedSinks.Add(from)) grew = true;
            foreach (var (retKey, sites) in returnCallSites)
                if (!escapedReturns.Contains(retKey) && !poisonedSinks.Contains(retKey)
                    && sites.Count > 0 && sites.All(s => checkedSinks.Contains(s)) && checkedSinks.Add(retKey)) grew = true;
        }
        foreach (var (msg, sink) in stored) (checkedSinks.Contains(sink) ? probes : fails).Add(msg);
    }

    // Every [HarmonyPatch] on one element, merged the way Harmony merges them: later wins.
    // The argument's TYPE says which field it is, so the ~20 constructor overloads need no table.
    void Merge(Target t, CustomAttributeHandleCollection attrs)
    {
        var r = mod.R;
        foreach (var h in attrs)
        {
            var ca = r.GetCustomAttribute(h);
            if (AttrName(r, ca) != "HarmonyLib.HarmonyPatch") continue;
            var v = ca.DecodeValue(this);
            var strs = new List<string>();
            foreach (var a in v.FixedArguments)
            {
                if (a.Type == "System.Type" && a.Value is string ty) { t.Type = ty; t.ByName = false; }
                else if (a.Type == "System.String" && a.Value is string s) strs.Add(s);
                else if (a.Type == "HarmonyLib.MethodType" && a.Value is int k) t.Kind = k;
                else if (a.Type == "System.Type[]" && a.Value is ImmutableArray<CustomAttributeTypedArgument<string>> arr)
                    t.Args = arr.Select(e => Norm((string)e.Value ?? "")).ToArray();
            }
            // (string typeName, string methodName) is the only two-string form.
            if (strs.Count >= 2) { t.Type = strs[0]; t.Method = strs[1]; t.ByName = true; }
            else if (strs.Count == 1) t.Method = strs[0];
        }
    }

    static readonly string[] PatchNames = { "Prefix", "Postfix", "Transpiler", "Finalizer", "ILManipulator" };

    static string PatchKind(MetadataReader r, MethodDefinition m)
    {
        foreach (var h in m.GetCustomAttributes())
            switch (AttrName(r, r.GetCustomAttribute(h)))
            {
                case "HarmonyLib.HarmonyPrefix": return "Prefix";
                case "HarmonyLib.HarmonyPostfix": return "Postfix";
                case "HarmonyLib.HarmonyFinalizer": return "Finalizer";
                case "HarmonyLib.HarmonyTranspiler":
                case "HarmonyLib.HarmonyILManipulator": return "Transpiler";
                case "HarmonyLib.HarmonyReversePatch": return "ReversePatch";
            }
        var n = r.GetString(m.Name);
        return PatchNames.Contains(n) ? n : null;
    }

    void CheckAttributes()
    {
        var r = mod.R;
        foreach (var th in r.TypeDefinitions)
        {
            var td = r.GetTypeDefinition(th);
            var methods = td.GetMethods().Select(r.GetMethodDefinition).ToList();
            bool classHas = Has(r, td.GetCustomAttributes(), "HarmonyLib.HarmonyPatch");
            if (!classHas && !methods.Any(m => Has(r, m.GetCustomAttributes(), "HarmonyLib.HarmonyPatch"))) continue;
            // TargetMethod(s) computes the target at runtime: nothing static to check.
            if (methods.Any(m => r.GetString(m.Name) is "TargetMethod" or "TargetMethods"
                || Has(r, m.GetCustomAttributes(), "HarmonyLib.HarmonyTargetMethod", "HarmonyLib.HarmonyTargetMethods"))) { nComputed++; continue; }
            var classT = new Target();
            Merge(classT, td.GetCustomAttributes());
            var typeName = Name(r, th);
            foreach (var m in methods)
            {
                var kind = PatchKind(r, m);
                bool mHas = Has(r, m.GetCustomAttributes(), "HarmonyLib.HarmonyPatch");
                if ((kind == null && !mHas) || (!classHas && !mHas)) continue;
                var t = classT.Clone();
                Merge(t, m.GetCustomAttributes());
                if (t.Type == null) { nComputed++; continue; }
                var where = Where(typeName, r.GetString(m.Name));
                var err = Resolve(t, out var ta, out var tdef, out var target, out var label);
                if (err != null) { fails.Add($"{err} {where}"); continue; }
                if (ta == null) continue; // in an assembly not loaded: counted by Resolve
                nChecked++;
                if (listTargets) oks.Add($"OK {label} {where}");
                if (kind is "Prefix" or "Postfix" or "Finalizer") CheckParams(m, kind, ta, tdef, target, label, where);
            }
        }
    }

    static string Have(IEnumerable<ImmutableArray<string>> sigs)
    {
        var l = sigs.Select(p => "(" + string.Join(", ", p) + ")").ToList();
        return l.Count == 0 ? "" : "; have " + string.Join(" | ", l);
    }

    // null = resolved (or nothing checkable); otherwise the finding.
    string Resolve(Target t, out Asm a, out TypeDefinition td, out MethodDefinition? target, out string label)
    {
        a = null; td = default; target = null;
        var tn = FindType(t.Type, t.ByName);
        label = tn ?? Norm(t.Type);
        if (tn == null)
        {
            if (Unloaded(AsmOf(t.Type), label)) { nUnloaded++; return null; }
            return $"type {label} not found";
        }
        Get(tn, out var x);
        a = x.A;
        var r = a.R;
        td = r.GetTypeDefinition(x.H);
        int kind = t.Kind ?? 0;
        if (kind is 1 or 2)
        {
            label = $"{tn}.{t.Method}";
            foreach (var ph in td.GetProperties())
            {
                var pd = r.GetPropertyDefinition(ph);
                if (r.GetString(pd.Name) != t.Method) continue;
                var acc = kind == 1 ? pd.GetAccessors().Getter : pd.GetAccessors().Setter;
                if (acc.IsNil) return $"{label} has no {(kind == 1 ? "getter" : "setter")}";
                target = r.GetMethodDefinition(acc);
                return null;
            }
            return $"{label} property not found";
        }
        string name = kind == 3 ? ".ctor" : kind == 4 ? ".cctor" : t.Method;
        if (name == null) return null;
        label = kind == 3 ? $"{tn} constructor" : kind == 4 ? $"{tn} static constructor" : $"{tn}.{name}";
        var ms = td.GetMethods().Select(r.GetMethodDefinition).Where(m => r.GetString(m.Name) == name)
            .Select(m => (M: m, P: m.DecodeSignature(this, null).ParameterTypes)).ToList();
        // DeclaredConstructor with no argumentTypes means the parameterless one.
        var args = t.Args ?? (kind == 3 ? Array.Empty<string>() : null);
        var have = "";
        if (args != null && kind != 4)
        {
            // Type.GetMethod(name, flags, null, argumentTypes, ...) with the default binder:
            // the exact signature, else any overload the arguments are assignable to.
            var exact = ms.Where(m => m.P.SequenceEqual(args)).ToList();
            if (exact.Count == 0) { have = Have(ms.Select(m => m.P)); exact = ms.Where(m => Fits(m.P, args)).ToList(); }
            ms = exact;
            label += "(" + string.Join(", ", args) + ")";
        }
        if (ms.Count == 0) return $"{label} not found{have}";
        if (ms.Count > 1 && args == null) return $"{label} is ambiguous: {ms.Count} overloads and no argumentTypes";
        // Enumerator/Async patch MoveNext, whose parameters are not the method's.
        if (kind is not (5 or 6)) target = ms[0].M;
        return null;
    }

    bool Fits(ImmutableArray<string> par, string[] args) =>
        par.Length == args.Length && par.Zip(args, Assignable).All(b => b);

    // The default binder's test, on names: the same type, object, a generic parameter
    // (inferred), or a base type / interface of the argument. A type outside the loaded set
    // cannot be judged and passes.
    // ponytail: primitive widening (int for a long) and enum-for-underlying are binder rules
    // not modelled -- add them when a real mod trips them.
    bool Assignable(string to, string from)
    {
        if (from == null || to == from || to == "System.Object" || to.StartsWith("!")) return true;
        if (to.EndsWith("[]") && from.EndsWith("[]")) return Assignable(to[..^2], from[..^2]);
        var todo = new Stack<string>();
        todo.Push(from);
        var seen = new HashSet<string>();
        while (todo.Count > 0)
        {
            var n = todo.Pop();
            if (n == null) return true;
            if (n == to) return true;
            if (!seen.Add(n)) continue;
            if (!Get(n, out var x)) return true;
            var r = x.A.R;
            var d = r.GetTypeDefinition(x.H);
            if (!d.BaseType.IsNil) todo.Push(BaseName(r, d.BaseType));
            foreach (var ih in d.GetInterfaceImplementations()) todo.Push(BaseName(r, r.GetInterfaceImplementation(ih).Interface));
        }
        return false;
    }

    void CheckParams(MethodDefinition pm, string kind, Asm ta, TypeDefinition td, MethodDefinition? target, string label, string where)
    {
        var r = mod.R;
        var sig = pm.DecodeSignature(this, null);
        // [HarmonyArgument] renames a parameter; on the method it can rename any of them.
        bool renames = Has(r, pm.GetCustomAttributes(), "HarmonyLib.HarmonyArgument");
        var names = target is MethodDefinition t
            ? t.GetParameters().Select(ta.R.GetParameter).Where(p => p.SequenceNumber > 0).Select(p => ta.R.GetString(p.Name)).ToHashSet()
            : null;
        foreach (var ph in pm.GetParameters())
        {
            var p = r.GetParameter(ph);
            if (p.SequenceNumber == 0) continue;
            var n = r.GetString(p.Name);
            if (n.StartsWith("___"))
            {
                if (!HasMember(ta, td, n.Substring(3), false, "field"))
                    (stripped ? refOnly : fails).Add($"{label}: field {n.Substring(3)} not found (parameter {n}) {where}");
                continue;
            }
            if (n.StartsWith("__") || names == null || renames || names.Contains(n)) continue;
            if (Has(r, p.GetCustomAttributes(), "HarmonyLib.HarmonyArgument")) continue;
            var ptype = sig.ParameterTypes[p.SequenceNumber - 1];
            // A pass-through postfix takes the result as its first parameter, under any name.
            if (kind == "Postfix" && p.SequenceNumber == 1 && ptype == sig.ReturnType) continue;
            // A delegate parameter is Harmony's [HarmonyDelegate] injection, not an argument.
            if (IsDelegate(ptype)) continue;
            fails.Add($"{label} has no parameter '{n}' {where}");
        }
    }

    bool IsDelegate(string type)
    {
        if (!Get(type, out var x)) return false;
        var b = x.A.R.GetTypeDefinition(x.H).BaseType;
        return !b.IsNil && BaseName(x.A.R, b) == "System.MulticastDelegate";
    }

    string BaseName(MetadataReader r, EntityHandle b) => b.Kind switch
    {
        HandleKind.TypeDefinition => Name(r, (TypeDefinitionHandle)b),
        HandleKind.TypeReference => Name(r, (TypeReferenceHandle)b),
        HandleKind.TypeSpecification => r.GetTypeSpecification((TypeSpecificationHandle)b).DecodeSignature(this, null),
        _ => null,
    };

    // AccessTools.Field/Method/Property walk base types; the Declared* forms do not.
    bool HasMember(Asm a, TypeDefinition td, string name, bool declaredOnly, string what)
    {
        stripped = a.Ref; // the looked-up type only: a stripped System.Object must not hide a game type's missing field
        for (int guard = 0; guard < 64; guard++)
        {
            var r = a.R;
            bool hit = what switch
            {
                "field" => td.GetFields().Any(h => r.GetString(r.GetFieldDefinition(h).Name) == name),
                "method" => td.GetMethods().Any(h => r.GetString(r.GetMethodDefinition(h).Name) == name),
                _ => td.GetProperties().Any(h => r.GetString(r.GetPropertyDefinition(h).Name) == name),
            };
            if (hit) return true;
            if (declaredOnly || td.BaseType.IsNil) return false;
            var bn = BaseName(r, td.BaseType);
            if (bn == null || !Get(bn, out var x)) return true; // base not in the set: cannot say
            a = x.A;
            td = a.R.GetTypeDefinition(x.H);
        }
        return true;
    }

    // Every overload of `name` on the type and, unless declaredOnly, its base types.
    // open = the walk left the loaded set, so an absence proves nothing.
    List<ImmutableArray<string>> Overloads(Asm a, TypeDefinition td, string name, bool declaredOnly, out bool open)
    {
        var res = new List<ImmutableArray<string>>();
        open = true;
        stripped = a.Ref; // the looked-up type only: a stripped System.Object must not hide a game type's missing field
        for (int guard = 0; guard < 64; guard++)
        {
            var r = a.R;
            foreach (var h in td.GetMethods())
            {
                var m = r.GetMethodDefinition(h);
                if (r.GetString(m.Name) == name) res.Add(m.DecodeSignature(this, null).ParameterTypes);
            }
            if (declaredOnly || td.BaseType.IsNil) { open = false; return res; }
            var bn = BaseName(r, td.BaseType);
            if (bn == null || !Get(bn, out var x)) return res;
            a = x.A;
            td = a.R.GetTypeDefinition(x.H);
        }
        return res;
    }

    // ---- IL ------------------------------------------------------------------------------

    static readonly Dictionary<ushort, OpCode> Ops = typeof(OpCodes)
        .GetFields(BindingFlags.Public | BindingFlags.Static)
        .Select(f => (OpCode)f.GetValue(null)).ToDictionary(o => (ushort)o.Value);

    readonly struct Ins
    {
        public readonly int Off, Arg;
        public readonly OpCode Op;
        public readonly int[] Switch;
        public Ins(int off, OpCode op, int arg, int[] sw = null) { Off = off; Op = op; Arg = arg; Switch = sw; }
    }

    static List<Ins> Decode(BlobReader il, HashSet<int> targets)
    {
        var list = new List<Ins>();
        while (il.RemainingBytes > 0)
        {
            int off = il.Offset;
            ushort v = il.ReadByte();
            if (v == 0xFE) v = (ushort)(0xFE00 | il.ReadByte());
            if (!Ops.TryGetValue(v, out var op)) return null;
            int arg = 0;
            int[] sw = null;
            switch (op.OperandType)
            {
                case OperandType.InlineNone: break;
                case OperandType.ShortInlineBrTarget: arg = il.ReadSByte(); targets.Add(il.Offset + arg); break;
                case OperandType.InlineBrTarget: arg = il.ReadInt32(); targets.Add(il.Offset + arg); break;
                case OperandType.ShortInlineI: arg = op == OpCodes.Ldc_I4_S ? il.ReadSByte() : il.ReadByte(); break;
                case OperandType.ShortInlineVar: arg = il.ReadByte(); break;
                case OperandType.InlineVar: arg = il.ReadUInt16(); break;
                case OperandType.InlineI8:
                case OperandType.InlineR: il.ReadInt64(); break;
                case OperandType.InlineSwitch:
                    int n = il.ReadInt32(), end = il.Offset + 4 * n;
                    sw = new int[n];
                    for (int k = 0; k < n; k++) { int to = end + il.ReadInt32(); sw[k] = to; targets.Add(to); }
                    break;
                default: arg = il.ReadInt32(); break;
            }
            list.Add(new Ins(off, op, arg, sw));
        }
        return list;
    }

    static EntityHandle Tok(int t) => MetadataTokens.EntityHandle(t);

    static int? Ldc(Ins x)
    {
        int v = x.Op.Value;
        if (v >= 0x15 && v <= 0x1E) return v - 0x16; // ldc.i4.m1 .. ldc.i4.8
        if (x.Op == OpCodes.Ldc_I4_S || x.Op == OpCodes.Ldc_I4) return x.Arg;
        return null;
    }

    static int Loc(Ins x, bool store)
    {
        int v = x.Op.Value;
        if (store)
        {
            if (v >= 0x0A && v <= 0x0D) return v - 0x0A; // stloc.0-3
            if (x.Op == OpCodes.Stloc_S || x.Op == OpCodes.Stloc) return x.Arg;
        }
        else
        {
            if (v >= 0x06 && v <= 0x09) return v - 0x06; // ldloc.0-3
            if (x.Op == OpCodes.Ldloc_S || x.Op == OpCodes.Ldloc) return x.Arg;
        }
        return -1;
    }

    // Pop1_pop1 -> 2, Popi_popi_popi -> 3, Pop0/Push0 -> 0. Varpop/Varpush occur only on the
    // calls and returns handled before this is asked.
    static int Count(StackBehaviour b)
    {
        var s = b.ToString();
        return s.EndsWith("0") || s.StartsWith("Var") ? 0 : s.Split('_').Length;
    }

    static bool BranchOnValue(OpCode op) =>
        op == OpCodes.Brtrue || op == OpCodes.Brtrue_S || op == OpCodes.Brfalse || op == OpCodes.Brfalse_S;

    // The value just pushed is tested against null at k: `x?.`, `x ?? y`, `if (x != null)`.
    bool NullCheckAt(List<Ins> ins, int k)
    {
        if (k >= ins.Count) return false;
        var op = ins[k].Op;
        if (BranchOnValue(op)) return true;
        if (k + 1 >= ins.Count) return false;
        var next = ins[k + 1].Op;
        if (op == OpCodes.Dup) return BranchOnValue(next);
        if (op != OpCodes.Ldnull) return false;
        if (next == OpCodes.Ceq || next == OpCodes.Cgt_Un || next == OpCodes.Beq || next == OpCodes.Beq_S
            || next == OpCodes.Bne_Un || next == OpCodes.Bne_Un_S) return true;
        return next == OpCodes.Call && Callee(mod.R, Tok(ins[k + 1].Arg)).Name is "op_Equality" or "op_Inequality";
    }

    // Build CFG successors (including switch and exception handler edges) and offset map for `ins`.
    static (Dictionary<int, int> OffToIdx, List<int>[] Succ) BuildCfg(MethodBodyBlock body, List<Ins> ins)
    {
        var offToIdx = new Dictionary<int, int>(ins.Count);
        for (int idx = 0; idx < ins.Count; idx++) offToIdx[ins[idx].Off] = idx;
        var succ = new List<int>[ins.Count];
        for (int j = 0; j < ins.Count; j++)
        {
            var list = new List<int>(2);
            var jop = ins[j].Op;
            bool fall = jop.FlowControl is not (FlowControl.Branch or FlowControl.Return or FlowControl.Throw);
            if (fall && j + 1 < ins.Count) list.Add(j + 1);
            if (jop.OperandType is OperandType.ShortInlineBrTarget or OperandType.InlineBrTarget)
            {
                if (j + 1 < ins.Count && offToIdx.TryGetValue(ins[j + 1].Off + ins[j].Arg, out int t)) list.Add(t);
            }
            else if (ins[j].Switch != null)
            {
                foreach (int off in ins[j].Switch) if (offToIdx.TryGetValue(off, out int t)) list.Add(t);
            }
            foreach (var er in body.ExceptionRegions)
                if (ins[j].Off >= er.TryOffset && ins[j].Off < er.TryOffset + er.TryLength && offToIdx.TryGetValue(er.HandlerOffset, out int ht))
                    list.Add(ht);
            succ[j] = list;
        }
        return (offToIdx, succ);
    }

    // If the value loaded at `j` is null-tested by a conditional branch, returns the branch
    // edge `(From, To)` along which the value is guaranteed non-null.
    (int From, int To)? NonNullBranchEdge(List<Ins> ins, Dictionary<int, int> offToIdx, int j)
    {
        if (j + 1 >= ins.Count) return null;
        int BrTarget(int b) => b + 1 < ins.Count && offToIdx.TryGetValue(ins[b + 1].Off + ins[b].Arg, out var t) ? t : -1;
        int k = j + 1;
        if (ins[k].Op == OpCodes.Dup && k + 1 < ins.Count) k++;
        var op1 = ins[k].Op;
        if (op1 == OpCodes.Brfalse || op1 == OpCodes.Brfalse_S) return k + 1 < ins.Count ? (k, k + 1) : null;
        if (op1 == OpCodes.Brtrue || op1 == OpCodes.Brtrue_S) { int t = BrTarget(k); return t >= 0 ? (k, t) : null; }
        if (op1 != OpCodes.Ldnull || k + 1 >= ins.Count) return null;
        var op2 = ins[k + 1].Op;
        if (op2 == OpCodes.Beq || op2 == OpCodes.Beq_S) return k + 2 < ins.Count ? (k + 1, k + 2) : null;
        if (op2 == OpCodes.Bne_Un || op2 == OpCodes.Bne_Un_S) { int t = BrTarget(k + 1); return t >= 0 ? (k + 1, t) : null; }
        bool eqNull = op2 == OpCodes.Ceq || (op2 == OpCodes.Call && Callee(mod.R, Tok(ins[k + 1].Arg)).Name == "op_Equality");
        bool neqNull = op2 == OpCodes.Cgt_Un || (op2 == OpCodes.Call && Callee(mod.R, Tok(ins[k + 1].Arg)).Name == "op_Inequality");
        if (!eqNull && !neqNull) return null;
        int b = k + 2;
        // Debug builds spill the bool comparison into a temp local before branching.
        if (b + 2 < ins.Count && Loc(ins[b], true) is int tb && tb >= 0 && Loc(ins[b + 1], false) == tb) b += 2;
        if (b >= ins.Count) return null;
        var bop = ins[b].Op;
        if (bop == OpCodes.Brtrue || bop == OpCodes.Brtrue_S) { int to = eqNull ? b + 1 : BrTarget(b); return to >= 0 && to < ins.Count ? (b, to) : null; }
        if (bop == OpCodes.Brfalse || bop == OpCodes.Brfalse_S) { int to = eqNull ? BrTarget(b) : b + 1; return to >= 0 && to < ins.Count ? (b, to) : null; }
        return null;
    }

    static int ArgLoad(Ins x)
    {
        int v = x.Op.Value;
        return v >= 0x02 && v <= 0x05 ? v - 0x02 : x.Op == OpCodes.Ldarg_S || x.Op == OpCodes.Ldarg ? x.Arg : -1;
    }

    // True if a virtual `callvirt` can dispatch to a derived override whose body we cannot assume.
    bool IsOverridable(OpCode callOp, EntityHandle h)
    {
        if (callOp != OpCodes.Callvirt || h.Kind != HandleKind.MethodDefinition) return false;
        var md = mod.R.GetMethodDefinition((MethodDefinitionHandle)h);
        if ((md.Attributes & MethodAttributes.Virtual) == 0 || (md.Attributes & MethodAttributes.Final) != 0) return false;
        var td = mod.R.GetTypeDefinition(md.GetDeclaringType());
        return (td.Attributes & TypeAttributes.Sealed) == 0;
    }

    // Conservative return-nullness check for a same-assembly `ParamNullChecked` helper: returns
    // false ONLY when every `ret` is proven non-null (typeof/string/newobj/newarr or the already
    // null-guarded parameter `checkedArgIdx`). Unknown calls (`Fallback()`), `ldnull`, fields,
    // `starg` reassignments, or overridable virtual dispatches conservatively return true.
    bool MethodMayReturnNull(OpCode callOp, EntityHandle h, int checkedArgIdx)
    {
        if (IsOverridable(callOp, h) || h.Kind != HandleKind.MethodDefinition) return true;
        var md = mod.R.GetMethodDefinition((MethodDefinitionHandle)h);
        if (md.RelativeVirtualAddress == 0) return true;
        var body = mod.Pe.GetMethodBody(md.RelativeVirtualAddress);
        var targets = new HashSet<int>();
        var ins = Decode(body.GetILReader(), targets);
        if (ins == null || ins.Count == 0) return true;
        // Reassigning or taking the address of the checked parameter (`starg`/`ldarga`) invalidates its non-null proof.
        foreach (var ix in ins)
            if ((ix.Op == OpCodes.Starg || ix.Op == OpCodes.Starg_S || ix.Op == OpCodes.Ldarga || ix.Op == OpCodes.Ldarga_S) && ix.Arg == checkedArgIdx) return true;
        // A local is guaranteed non-null only if every store to it is proven non-null (handles Debug spill).
        var locNonNull = new Dictionary<int, bool>();
        var joinVal = new Dictionary<int, bool>();
        var st = new List<bool>();
        bool prevFall = false;
        bool PopB() { if (st.Count == 0) return false; bool v = st[^1]; st.RemoveAt(st.Count - 1); return v; }
        for (int j = 0; j < ins.Count; j++)
        {
            var x = ins[j];
            var op = x.Op;
            if (targets.Contains(x.Off))
            {
                bool hasJoin = joinVal.TryGetValue(x.Off, out bool jv);
                if (prevFall && st.Count > 0)
                {
                    bool fv = st[^1];
                    st.Clear();
                    st.Add(hasJoin ? (jv && fv) : fv);
                }
                else
                {
                    st.Clear();
                    if (hasJoin) st.Add(jv);
                }
            }
            prevFall = op.FlowControl is not (FlowControl.Branch or FlowControl.Return or FlowControl.Throw);
            if (op == OpCodes.Br || op == OpCodes.Br_S)
            {
                if (st.Count > 0 && j + 1 < ins.Count)
                {
                    int to = ins[j + 1].Off + x.Arg;
                    bool v = PopB();
                    joinVal[to] = joinVal.TryGetValue(to, out bool pv) ? (pv && v) : v;
                }
                st.Clear();
                continue;
            }
            if (op == OpCodes.Ret)
            {
                if (st.Count == 0 || !PopB()) return true;
                st.Clear();
                continue;
            }
            if (op == OpCodes.Ldstr) { st.Add(true); continue; }
            if (op == OpCodes.Ldnull || op == OpCodes.Ldtoken || Ldc(x) != null) { st.Add(false); continue; }
            if (op == OpCodes.Newarr) { PopB(); st.Add(true); continue; }
            if (op == OpCodes.Dup) { st.Add(st.Count > 0 && st[^1]); continue; }
            int a = ArgLoad(x);
            if (a >= 0) { st.Add(a == checkedArgIdx); continue; }
            int ld = Loc(x, false);
            if (ld >= 0) { st.Add(locNonNull.TryGetValue(ld, out bool ok) && ok); continue; }
            int sl = Loc(x, true);
            if (sl >= 0)
            {
                bool v = PopB();
                locNonNull[sl] = locNonNull.TryGetValue(sl, out bool prev) ? (prev && v) : v;
                continue;
            }
            if (op == OpCodes.Call || op == OpCodes.Callvirt || op == OpCodes.Newobj)
            {
                var (parent, name, sig, _) = Callee(mod.R, Tok(x.Arg));
                if (sig == null) return true;
                for (int k = 0; k < sig.Value.ParameterTypes.Length; k++) PopB();
                if (sig.Value.Header.IsInstance && op != OpCodes.Newobj) PopB();
                if (op == OpCodes.Newobj) st.Add(true);
                else if (sig.Value.ReturnType != "System.Void")
                    st.Add(parent == "System.Type" && name == "GetTypeFromHandle");
                continue;
            }
            if (op.FlowControl is FlowControl.Branch or FlowControl.Return or FlowControl.Throw || op == OpCodes.Calli) { st.Clear(); continue; }
            for (int k = Count(op.StackBehaviourPop); k > 0; k--) PopB();
            for (int k = Count(op.StackBehaviourPush); k > 0; k--) st.Add(false);
        }
        return false;
    }

    // A method of this assembly that null-checks its parameter k: `Method(Type type, ...)
    // { type == null ? null : ... }` handles the null a failed lookup hands it (#212),
    // provided no non-check use of parameter k is reachable along a path where k may be null.
    bool ParamNullChecked(OpCode callOp, EntityHandle h, bool instance, int k)
    {
        if (IsOverridable(callOp, h) || h.Kind != HandleKind.MethodDefinition) return false;
        var md = mod.R.GetMethodDefinition((MethodDefinitionHandle)h);
        if (md.RelativeVirtualAddress == 0) return false;
        var body = mod.Pe.GetMethodBody(md.RelativeVirtualAddress);
        var ins = Decode(body.GetILReader(), new HashSet<int>());
        if (ins == null || ins.Count == 0) return false;
        int idx = k + (instance ? 1 : 0);
        foreach (var ix in ins)
            if ((ix.Op == OpCodes.Starg || ix.Op == OpCodes.Starg_S || ix.Op == OpCodes.Ldarga || ix.Op == OpCodes.Ldarga_S) && ix.Arg == idx) return false;
        var (offToIdx, succ) = BuildCfg(body, ins);
        bool hasCheck = false;
        var nonNullEdges = new HashSet<(int, int)>();
        var unsafeUses = new HashSet<int>();
        for (int j = 0; j < ins.Count; j++)
        {
            if (ArgLoad(ins[j]) != idx) continue;
            if (NullCheckAt(ins, j + 1))
            {
                hasCheck = true;
                if (NonNullBranchEdge(ins, offToIdx, j) is (int from, int to)) nonNullEdges.Add((from, to));
            }
            else unsafeUses.Add(j);
        }
        if (!hasCheck) return false;
        if (unsafeUses.Count == 0) return true;
        var seen = new bool[ins.Count];
        var q = new Queue<int>();
        seen[0] = true;
        q.Enqueue(0);
        while (q.Count > 0)
        {
            int u = q.Dequeue();
            if (unsafeUses.Contains(u)) return false;
            if ((ins[u].Op == OpCodes.Starg || ins[u].Op == OpCodes.Starg_S) && ins[u].Arg == idx) continue;
            foreach (int v in succ[u])
            {
                if (seen[v] || nonNullEdges.Contains((u, v))) continue;
                seen[v] = true;
                q.Enqueue(v);
            }
        }
        return true;
    }

    static string Sink(Ins x, string locKey)
    {
        int l = Loc(x, true);
        if (l >= 0) return locKey + l;
        return x.Op == OpCodes.Stfld || x.Op == OpCodes.Stsfld ? "F" + x.Arg : null;
    }

    V TypeTok(MetadataReader r, EntityHandle h) => h.Kind switch
    {
        HandleKind.TypeDefinition => T(Name(r, (TypeDefinitionHandle)h)),
        HandleKind.TypeReference => T(Name(r, (TypeReferenceHandle)h), Scope(r, (TypeReferenceHandle)h)),
        HandleKind.TypeSpecification => T(r.GetTypeSpecification((TypeSpecificationHandle)h).DecodeSignature(this, null)),
        _ => null,
    };

    static string FieldName(MetadataReader r, EntityHandle h)
    {
        if (h.Kind != HandleKind.MemberReference) return null;
        var f = r.GetMemberReference((MemberReferenceHandle)h);
        return f.Parent.Kind == HandleKind.TypeReference ? Name(r, (TypeReferenceHandle)f.Parent) + "::" + r.GetString(f.Name) : null;
    }

    (string Parent, string Name, MethodSignature<string>? Sig, ImmutableArray<string> Gen) Callee(MetadataReader r, EntityHandle h)
    {
        var gen = ImmutableArray<string>.Empty;
        if (h.Kind == HandleKind.MethodSpecification)
        {
            var ms = r.GetMethodSpecification((MethodSpecificationHandle)h);
            gen = ms.DecodeSignature(this, null);
            h = ms.Method;
        }
        if (h.Kind == HandleKind.MethodDefinition)
        {
            var md = r.GetMethodDefinition((MethodDefinitionHandle)h);
            return (Name(r, md.GetDeclaringType()), r.GetString(md.Name), md.DecodeSignature(this, null), gen);
        }
        if (h.Kind != HandleKind.MemberReference) return (null, null, null, gen);
        var mr = r.GetMemberReference((MemberReferenceHandle)h);
        if (mr.GetKind() != MemberReferenceKind.Method) return (null, null, null, gen);
        return (BaseName(r, mr.Parent), r.GetString(mr.Name), mr.DecodeMethodSignature(this, null), gen);
    }

    // "PatchClass|TypeName" pairs a Prepare() null-checks TypeByName("TypeName") for. Prepare
    // false skips the whole patch class: Harmony never calls its TargetMethod (#215).
    // shortcut: any null check counts (`== null` too) and only a literal TypeByName right before it;
    // read the branch direction / a stored local when a real mod needs it.
    HashSet<string> guards;
    string scanType, scanMethod;
    HashSet<string> PrepareGuards()
    {
        var r = mod.R;
        var g = new HashSet<string>(StringComparer.Ordinal);
        foreach (var mh in r.MethodDefinitions)
        {
            var m = r.GetMethodDefinition(mh);
            if (m.RelativeVirtualAddress == 0 || r.GetString(m.Name) != "Prepare") continue;
            List<Ins> ins;
            try { ins = Decode(mod.Pe.GetMethodBody(m.RelativeVirtualAddress).GetILReader(), new HashSet<int>()); }
            catch (BadImageFormatException) { continue; }
            catch (ArgumentException) { continue; }
            if (ins == null) continue;
            for (int i = 1; i < ins.Count; i++)
            {
                if (ins[i - 1].Op != OpCodes.Ldstr || ins[i].Op != OpCodes.Call || !NullCheckAt(ins, i + 1)) continue;
                var c = Callee(r, Tok(ins[i].Arg));
                if (c.Parent == "HarmonyLib.AccessTools" && c.Name == "TypeByName")
                    g.Add(Name(r, m.GetDeclaringType()) + "|" + Norm(r.GetUserString((UserStringHandle)MetadataTokens.Handle(ins[i - 1].Arg))));
            }
        }
        return g;
    }

    void CheckIL()
    {
        var r = mod.R;
        foreach (var mh in r.MethodDefinitions)
        {
            var m = r.GetMethodDefinition(mh);
            if (m.RelativeVirtualAddress == 0) continue;
            // A body this reader cannot follow (obfuscated, hand-written): nothing checked, nothing claimed.
            try { Scan(mh, m); }
            catch (BadImageFormatException) { }
            catch (ArgumentException) { }
        }
    }

    void Scan(MethodDefinitionHandle mh, MethodDefinition m)
    {
        var r = mod.R;
        var body = mod.Pe.GetMethodBody(m.RelativeVirtualAddress);
        var targets = new HashSet<int>();
        var ins = Decode(body.GetILReader(), targets);
        if (ins == null) return;
        bool hasRet = m.DecodeSignature(this, null).ReturnType != "System.Void";
        foreach (var er in body.ExceptionRegions)
        {
            targets.Add(er.HandlerOffset);
            if (er.Kind == ExceptionRegionKind.Filter) targets.Add(er.FilterOffset);
        }
        scanType = Name(r, m.GetDeclaringType());
        scanMethod = r.GetString(m.Name);
        var locKey = "L" + MetadataTokens.GetRowNumber(mh) + ":";
        var locVer = new Dictionary<int, int>();
        string CurLoc(int l) => locKey + l + "#" + (locVer.TryGetValue(l, out var v) ? v : 0);
        string NewLoc(int l) => locKey + l + "#" + (locVer[l] = (locVer.TryGetValue(l, out var v) ? v : 0) + 1);
        string PeekSink(Ins insNext)
        {
            int l = Loc(insNext, true);
            if (l >= 0) return locKey + l + "#" + ((locVer.TryGetValue(l, out var v) ? v : 0) + 1);
            return insNext.Op == OpCodes.Stfld || insNext.Op == OpCodes.Stsfld ? "F" + insNext.Arg : null;
        }
        void MarkChecked(string sink)
        {
            if (sink != null && !poisonedSinks.Contains(sink)) checkedSinks.Add(sink);
        }
        // Sound per-path nullness: track every local version's definition index and every unsafe
        // use (receiver deref or non-null-checked argument) by local SLOT or FIELD token, then run
        // forward may-be-null BFS over the CFG so conditional checks, conditional overwrites, or
        // method declaration order never mask an unchecked path.
        var locDefAt = new Dictionary<string, (int LocIdx, int InsIdx)>();
        var locUses = new Dictionary<int, HashSet<int>>();
        var fieldUses = new Dictionary<string, HashSet<int>>(StringComparer.Ordinal);
        void NoteDeref(V v, int at)
        {
            if (v?.Sink == null) return;
            if (v.Sink.StartsWith(locKey, StringComparison.Ordinal))
            {
                int sep = v.Sink.IndexOf('#', locKey.Length);
                if (sep > locKey.Length && int.TryParse(v.Sink.Substring(locKey.Length, sep - locKey.Length), out int slot))
                {
                    if (!locUses.TryGetValue(slot, out var set)) locUses[slot] = set = new();
                    set.Add(at);
                }
            }
            else if (v.Sink.StartsWith("F", StringComparison.Ordinal))
            {
                if (!fieldUses.TryGetValue(v.Sink, out var set)) fieldUses[v.Sink] = set = new();
                set.Add(at);
            }
            else poisonedSinks.Add(v.Sink);
        }
        var st = new List<V>();
        // Failed lookups whose null is followed to where it is checked; one never judged fails.
        var pending = new List<V>();
        void Judge(V v, bool probe)
        {
            if (v?.Pend == null || v.Done) return;
            v.Done = true;
            (probe ? probes : fails).Add(v.Pend);
        }
        V Pop()
        {
            if (st.Count == 0) return null;
            var v = st[^1];
            st.RemoveAt(st.Count - 1);
            return v;
        }
        for (int i = 0; i < ins.Count; i++)
        {
            var x = ins[i];
            var op = x.Op;
            // The stack at a join is not tracked: whatever it held is simply not known.
            if (targets.Contains(x.Off)) st.Clear();
            // A followed null tested later: Release keeps `var t = TypeByName(..)` on the stack under other lookups.
            if (st.Count > 0 && NullCheckAt(ins, i))
            {
                if (st[^1]?.Pend != null) Judge(st[^1], true);
                MarkChecked(st[^1]?.Sink);
            }
            // Where a stored lookup result is read back and null-checked.
            int li = Loc(x, false);
            if (li >= 0 && NullCheckAt(ins, i + 1)) MarkChecked(CurLoc(li));
            if ((op == OpCodes.Ldfld || op == OpCodes.Ldsfld) && NullCheckAt(ins, i + 1)) MarkChecked("F" + x.Arg);

            if ((op == OpCodes.Ldftn || op == OpCodes.Ldvirtftn) && Tok(x.Arg).Kind == HandleKind.MethodDefinition)
            {
                escapedReturns.Add("R" + MetadataTokens.GetRowNumber((MethodDefinitionHandle)Tok(x.Arg)));
                st.Add(null);
                continue;
            }
            if (op == OpCodes.Ldloca || op == OpCodes.Ldloca_S)
            {
                if (!locUses.TryGetValue(x.Arg, out var us)) locUses[x.Arg] = us = new();
                us.Add(i);
                st.Add(null);
                continue;
            }
            if (op == OpCodes.Ldflda || op == OpCodes.Ldsflda)
            {
                if (op == OpCodes.Ldflda) NoteDeref(Pop(), i);
                var fk = "F" + x.Arg;
                if (!fieldUses.TryGetValue(fk, out var fs)) fieldUses[fk] = fs = new();
                fs.Add(i);
                st.Add(null);
                continue;
            }
            if (op == OpCodes.Ldtoken) { st.Add(TypeTok(r, Tok(x.Arg))); continue; }
            if (op == OpCodes.Ldstr) { st.Add(new V { K = 's', S = r.GetUserString((UserStringHandle)MetadataTokens.Handle(x.Arg)) }); continue; }
            if (op == OpCodes.Ldnull) { st.Add(new V { K = '0' }); continue; }
            if (Ldc(x) is int c) { st.Add(new V { K = 'i', N = c }); continue; }
            if (op == OpCodes.Newarr)
            {
                var n = Pop();
                st.Add(n?.K == 'i' && n.N >= 0 && n.N <= 64 ? new V { K = 'a', Arr = new string[n.N] } : null);
                continue;
            }
            if (op == OpCodes.Dup) { st.Add(st.Count > 0 ? st[^1] : null); continue; }
            if (op == OpCodes.Isinst) { if (st.Count == 0) st.Add(null); continue; }
            if (op == OpCodes.Stelem_Ref)
            {
                var val = Pop(); var idx = Pop(); var arr = Pop();
                if (arr?.K == 'a' && idx?.K == 'i' && idx.N >= 0 && idx.N < arr.Arr.Length && val?.K == 'T') arr.Arr[idx.N] = val.S;
                continue;
            }
            if (op == OpCodes.Ldsfld && FieldName(r, Tok(x.Arg)) == "System.Type::EmptyTypes") { st.Add(new V { K = 'a', Arr = Array.Empty<string>() }); continue; }
            if (li >= 0) { st.Add(new V { Sink = CurLoc(li) }); continue; }
            if (op == OpCodes.Ldfld || op == OpCodes.Ldsfld)
            {
                if (op == OpCodes.Ldfld) NoteDeref(Pop(), i);
                st.Add(new V { Sink = "F" + x.Arg });
                continue;
            }
            if (op == OpCodes.Call || op == OpCodes.Callvirt || op == OpCodes.Newobj)
            {
                var (parent, name, sig, gen) = Callee(r, Tok(x.Arg));
                if (sig == null) { st.Clear(); continue; }
                var p = sig.Value.ParameterTypes;
                var a = new V[p.Length];
                for (int k = p.Length - 1; k >= 0; k--) a[k] = Pop();
                var self = sig.Value.Header.IsInstance && op != OpCodes.Newobj ? Pop() : null;
                Judge(self, false); // a member of null: the NullReferenceException itself
                NoteDeref(self, i);
                // AccessTools.Field/Method/Property(null, ...) return null (0Harmony: "type is null"),
                // so a failed TypeByName handed straight to them is judged by THAT result (#204).
                // FieldRefAccess throws on a null type.
                bool forwardType = a.Length > 0 && parent == "HarmonyLib.AccessTools"
                    && p[0] == "System.Type" && Kinds.ContainsKey(name) && !name.EndsWith("FieldRefAccess");
                V carry = forwardType && a[0]?.Pend != null && !a[0].Done ? a[0] : null;
                string sinkCarry = forwardType && carry == null ? a[0]?.Sink : null;
                var heldArgSinks = new List<(string Sink, int ArgIdx)>();
                bool isInstCall = sig.Value.Header.IsInstance && op != OpCodes.Newobj;
                for (int k = 0; k < a.Length; k++)
                {
                    if (a[k] == null || a[k] == carry || (k == 0 && sinkCarry != null) || (a[k].Pend == null && a[k].Sink == null)) continue;
                    bool held = ParamNullChecked(op, Tok(x.Arg), isInstCall, k);
                    if (held)
                    {
                        MarkChecked(a[k].Sink);
                        if (a[k].Sink != null) heldArgSinks.Add((a[k].Sink, k + (isInstCall ? 1 : 0)));
                    }
                    else if (name is not ("op_Equality" or "op_Inequality")) NoteDeref(a[k], i);
                    Judge(a[k], held);
                }
                V ret = null;
                if (carry != null)
                {
                    carry.Done = true;
                    ret = Fail(carry.Pend, i);
                    st.Add(ret);
                    continue;
                }
                if (sinkCarry != null)
                {
                    st.Add(Forward(sinkCarry, i));
                    continue;
                }
                if (parent == "System.Type" && name == "GetTypeFromHandle") ret = a[0];
                else if (parent == "System.Type" && name == "MakeByRefType") ret = self?.K == 'T' ? self : null; // byref is dropped from every name
                else if (parent == "System.Type" && name == "MakeArrayType" && p.Length == 0) ret = self?.K == 'T' ? T(self.S + "[]", self.Asm) : null;
                else if (parent == "System.Array" && name == "Empty") ret = new V { K = 'a', Arr = Array.Empty<string>() };
                else if (parent is "HarmonyLib.AccessTools" or "System.Type")
                {
                    var (msg, v) = Lookup(parent, name, p, a, self, gen);
                    ret = v;
                    if (okLookup != null) oks.Add("OK " + okLookup + " " + Where(Name(r, m.GetDeclaringType()), r.GetString(m.Name)));
                    if (msg != null)
                    {
                        msg += " " + Where(Name(r, m.GetDeclaringType()), r.GetString(m.Name));
                        if (stripped) refOnly.Add(msg);
                        else ret = Fail(msg, i);
                    }
                }
                else if (op != OpCodes.Newobj && Tok(x.Arg).Kind == HandleKind.MethodDefinition && sig.Value.ReturnType != "System.Void")
                {
                    var retKey = "R" + MetadataTokens.GetRowNumber((MethodDefinitionHandle)Tok(x.Arg));
                    var site = "C" + (++callSiteId);
                    if (!returnCallSites.TryGetValue(retKey, out var sites)) returnCallSites[retKey] = sites = new();
                    sites.Add(site);
                    // Unless the null-checking helper is proven to return non-null on every path,
                    // an unchecked dereference of its return value must still poison the argument sink.
                    foreach (var (hs, argIdx) in heldArgSinks)
                        if (MethodMayReturnNull(op, Tok(x.Arg), argIdx)) sinkLinks.Add((hs, site));
                    ret = Forward(site, i);
                }
                if (op == OpCodes.Newobj || sig.Value.ReturnType != "System.Void") st.Add(ret);
                continue;
            }
            if (op == OpCodes.Ret)
            {
                if (hasRet && st.Count > 0)
                {
                    var rv = Pop();
                    var retSink = "R" + MetadataTokens.GetRowNumber(mh);
                    if (rv?.Pend != null && !rv.Done) { rv.Done = true; stored.Add((rv.Pend, retSink)); }
                    else if (rv?.Sink != null) sinkLinks.Add((rv.Sink, retSink));
                }
                st.Clear();
                continue;
            }
            int stLoc = Loc(x, true);
            if (stLoc >= 0 || op == OpCodes.Stfld || op == OpCodes.Stsfld)
            {
                var sv = Pop();
                if (op == OpCodes.Stfld) NoteDeref(Pop(), i);
                string dst = stLoc >= 0 ? NewLoc(stLoc) : "F" + x.Arg;
                if (stLoc >= 0) locDefAt[dst] = (stLoc, i);
                if (sv?.Pend != null && !sv.Done) { sv.Done = true; stored.Add((sv.Pend, dst)); }
                else if (sv?.Sink != null) sinkLinks.Add((sv.Sink, dst));
                continue;
            }
            if (op.FlowControl is FlowControl.Branch or FlowControl.Return or FlowControl.Throw || op == OpCodes.Calli) { st.Clear(); continue; }
            for (int k = Count(op.StackBehaviourPop); k > 0; k--) Pop();
            for (int k = Count(op.StackBehaviourPush); k > 0; k--) st.Add(null);
        }
        foreach (var v in pending) Judge(v, false); // returned, passed on, dropped: not shown to be checked
        if ((locUses.Count > 0 && locDefAt.Count > 0) || fieldUses.Count > 0)
        {
            var (offToIdx, succ) = BuildCfg(body, ins);
            // For each conditional branch instruction that null-checks a local or field, record
            // which outgoing edge (brIdx -> nonNullTargetIdx) guarantees it is non-null.
            // Static fields (`ldsfld`) share one location; instance fields (`ldfld`) only qualify
            // when every load of that field in this method is off `this` (`ldarg.0`, never `a.F`/`b.F`).
            var nonThisFieldLoads = new HashSet<string>(StringComparer.Ordinal);
            for (int j = 0; j < ins.Count; j++)
            {
                if (ins[j].Op == OpCodes.Ldfld && !(j > 0 && ins[j - 1].Op == OpCodes.Ldarg_0 && !targets.Contains(ins[j].Off)))
                    nonThisFieldLoads.Add("F" + ins[j].Arg);
            }
            var nonNullEdge = new Dictionary<(int From, int To), HashSet<int>>();
            var nonNullFieldEdge = new Dictionary<(int From, int To), HashSet<string>>();
            for (int j = 0; j < ins.Count; j++)
            {
                int l = Loc(ins[j], false);
                if (l >= 0 && NonNullBranchEdge(ins, offToIdx, j) is (int from, int to))
                {
                    if (!nonNullEdge.TryGetValue((from, to), out var set)) nonNullEdge[(from, to)] = set = new();
                    set.Add(l);
                    continue;
                }
                bool safeFieldLoad = ins[j].Op == OpCodes.Ldsfld
                    || (ins[j].Op == OpCodes.Ldfld && !nonThisFieldLoads.Contains("F" + ins[j].Arg) && m.DecodeSignature(this, null).Header.IsInstance);
                if (safeFieldLoad && NonNullBranchEdge(ins, offToIdx, j) is (int fFrom, int fTo))
                {
                    if (!nonNullFieldEdge.TryGetValue((fFrom, fTo), out var fset)) nonNullFieldEdge[(fFrom, fTo)] = fset = new(StringComparer.Ordinal);
                    fset.Add("F" + ins[j].Arg);
                }
            }
            foreach (var (dSink, def) in locDefAt)
            {
                if (poisonedSinks.Contains(dSink) || !locUses.TryGetValue(def.LocIdx, out var uses)) continue;
                var seen = new bool[ins.Count];
                var q = new Queue<int>();
                foreach (int nx in succ[def.InsIdx]) { seen[nx] = true; q.Enqueue(nx); }
                bool reachableNull = false;
                while (q.Count > 0)
                {
                    int u = q.Dequeue();
                    if (uses.Contains(u)) { reachableNull = true; break; }
                    if (Loc(ins[u], true) == def.LocIdx) continue; // overwritten by a later assignment
                    foreach (int v in succ[u])
                    {
                        if (seen[v]) continue;
                        if (nonNullEdge.TryGetValue((u, v), out var nn) && nn.Contains(def.LocIdx)) continue;
                        seen[v] = true;
                        q.Enqueue(v);
                    }
                }
                if (reachableNull) { poisonedSinks.Add(dSink); checkedSinks.Remove(dSink); }
            }
            // Fields: order-independent per-method CFG check from method entry (0), from every
            // write (`stfld`/`stsfld`) to F, and (for non-readonly fields) after any call in this
            // method that may mutate F. A private field never written outside .ctor/.cctor cannot
            // be mutated by any call; once any non-ctor method writes F (or F is non-private), any
            // external/delegate/overridable/indirect call conservatively counts as a potential write.
            bool IsInitOnlyField(int tokVal)
            {
                var fh = Tok(tokVal);
                return fh.Kind == HandleKind.FieldDefinition && (mod.R.GetFieldDefinition((FieldDefinitionHandle)fh).Attributes & FieldAttributes.InitOnly) != 0;
            }
            bool IsPrivateField(int tokVal)
            {
                var fh = Tok(tokVal);
                return fh.Kind == HandleKind.FieldDefinition
                    && (mod.R.GetFieldDefinition((FieldDefinitionHandle)fh).Attributes & FieldAttributes.FieldAccessMask) == FieldAttributes.Private;
            }
            bool WrittenOutsideCtor(string targetField)
            {
                foreach (var omh in mod.R.MethodDefinitions)
                {
                    var omd = mod.R.GetMethodDefinition(omh);
                    if (omd.RelativeVirtualAddress == 0) continue;
                    var oname = mod.R.GetString(omd.Name);
                    if (oname is ".ctor" or ".cctor") continue;
                    var oins = Decode(mod.Pe.GetMethodBody(omd.RelativeVirtualAddress).GetILReader(), new HashSet<int>());
                    if (oins == null) return true;
                    foreach (var ox in oins)
                        if ((ox.Op == OpCodes.Stfld || ox.Op == OpCodes.Stsfld || ox.Op == OpCodes.Ldflda || ox.Op == OpCodes.Ldsflda)
                            && ("F" + ox.Arg) == targetField) return true;
                }
                return false;
            }
            bool MethodMayWriteField(OpCode callOp, EntityHandle ch, string targetField, bool anyExternalMayWrite, HashSet<int> vis)
            {
                if (callOp == OpCodes.Calli || IsOverridable(callOp, ch)) return anyExternalMayWrite;
                if (ch.Kind != HandleKind.MethodDefinition) return anyExternalMayWrite;
                var mHandle = (MethodDefinitionHandle)ch;
                int row = MetadataTokens.GetRowNumber(mHandle);
                if (!vis.Add(row)) return false;
                var md = mod.R.GetMethodDefinition(mHandle);
                if (md.RelativeVirtualAddress == 0) return anyExternalMayWrite;
                var mins = Decode(mod.Pe.GetMethodBody(md.RelativeVirtualAddress).GetILReader(), new HashSet<int>());
                if (mins == null) return true;
                foreach (var mx in mins)
                {
                    var mop = mx.Op;
                    if ((mop == OpCodes.Stfld || mop == OpCodes.Stsfld || mop == OpCodes.Ldflda || mop == OpCodes.Ldsflda)
                        && ("F" + mx.Arg) == targetField) return true;
                    if ((mop == OpCodes.Call || mop == OpCodes.Callvirt || mop == OpCodes.Calli || mop == OpCodes.Newobj)
                        && MethodMayWriteField(mop, mop == OpCodes.Calli ? default : Tok(mx.Arg), targetField, anyExternalMayWrite, vis)) return true;
                }
                return false;
            }
            foreach (var (fSink, uses) in fieldUses)
            {
                if (poisonedSinks.Contains(fSink) || ins.Count == 0) continue;
                int fTok = 0;
                bool hasTok = int.TryParse(fSink.Substring(1), out fTok);
                bool isReadonly = hasTok && IsInitOnlyField(fTok);
                bool isPriv = hasTok && IsPrivateField(fTok);
                bool mayMutateByCall = !isReadonly && (!isPriv || WrittenOutsideCtor(fSink));
                var seen = new bool[ins.Count];
                var q = new Queue<int>();
                seen[0] = true;
                q.Enqueue(0);
                for (int w = 0; w < ins.Count; w++)
                {
                    var wop = ins[w].Op;
                    bool mutates = ((wop == OpCodes.Stfld || wop == OpCodes.Stsfld) && ("F" + ins[w].Arg) == fSink)
                        || (mayMutateByCall && (wop == OpCodes.Call || wop == OpCodes.Callvirt || wop == OpCodes.Calli || wop == OpCodes.Newobj)
                            && !(wop == OpCodes.Call && Callee(mod.R, Tok(ins[w].Arg)).Name is "op_Equality" or "op_Inequality")
                            && MethodMayWriteField(wop, wop == OpCodes.Calli ? default : Tok(ins[w].Arg), fSink, true, new HashSet<int>()));
                    if (mutates)
                    {
                        foreach (int nx in succ[w]) if (!seen[nx]) { seen[nx] = true; q.Enqueue(nx); }
                    }
                }
                bool reachableNull = false;
                while (q.Count > 0)
                {
                    int u = q.Dequeue();
                    if (uses.Contains(u)) { reachableNull = true; break; }
                    foreach (int v in succ[u])
                    {
                        if (seen[v]) continue;
                        if (nonNullFieldEdge.TryGetValue((u, v), out var nn) && nn.Contains(fSink)) continue;
                        seen[v] = true;
                        q.Enqueue(v);
                    }
                }
                if (reachableNull) { poisonedSinks.Add(fSink); checkedSinks.Remove(fSink); }
            }
        }

        V Forward(string sink, int i)
        {
            if (NullCheckAt(ins, i + 1)) { MarkChecked(sink); return null; }
            if (i + 1 < ins.Count && PeekSink(ins[i + 1]) is string nextSink) { sinkLinks.Add((sink, nextSink)); return null; }
            return new V { Sink = sink };
        }

        // A failed lookup's result at i: null-checked right here, stored (judged where it is
        // read back), or followed on the stack.
        V Fail(string msg, int i)
        {
            if (NullCheckAt(ins, i + 1)) { probes.Add(msg); return null; }
            if (i + 1 < ins.Count && PeekSink(ins[i + 1]) is string sink) { stored.Add((msg, sink)); return null; }
            var v = new V { Pend = msg };
            pending.Add(v);
            return v;
        }
    }

    static readonly Dictionary<string, string> Kinds = new()
    {
        ["Method"] = "method", ["DeclaredMethod"] = "method", ["GetMethod"] = "method",
        ["Field"] = "field", ["DeclaredField"] = "field", ["GetField"] = "field",
        ["FieldRefAccess"] = "field", ["StaticFieldRefAccess"] = "field",
        ["Property"] = "property", ["DeclaredProperty"] = "property", ["GetProperty"] = "property",
        ["PropertyGetter"] = "property", ["PropertySetter"] = "property",
        ["DeclaredPropertyGetter"] = "property", ["DeclaredPropertySetter"] = "property",
    };

    // One reflection call: (the finding or null, the value it leaves on the stack).
    // ponytail: Type.GetX's BindingFlags are read for DeclaredOnly only -- a private member
    // looked up without NonPublic is not flagged; add visibility when a real mod needs it.
    (string, V) Lookup(string parent, string api, ImmutableArray<string> p, V[] a, V self, ImmutableArray<string> gen)
    {
        bool harmony = parent == "HarmonyLib.AccessTools";
        var label = (harmony ? "AccessTools." : "Type.") + api;
        okLookup = null;
        stripped = false;
        if (harmony && api == "TypeByName" && p.Length == 1)
        {
            if (a[0]?.K != 's') { nDynamic++; return (null, null); }
            var hit = FindType(a[0].S, true);
            if (hit == null && Unloaded(AsmOf(a[0].S), Norm(a[0].S))) { nUnloaded++; return (null, null); }
            // Prepare() guards this type: absent, the patch is skipped (Prepare's own lookup still warns).
            // 'G' tells the member lookup it is handed to that there is nothing to check.
            if (hit == null && scanMethod != "Prepare" && guards.Contains(scanType + "|" + Norm(a[0].S))) { nUnloaded++; return (null, new V { K = 'G' }); }
            nChecked++;
            if (hit == null) return ($"type {Norm(a[0].S)} not found ({label})", null);
            if (listTargets) okLookup = $"type {hit} ({label})";
            return (null, T(hit));
        }
        if (!Kinds.TryGetValue(api, out var what)) return (null, null);
        V type = null, member = null, typeArgs = null;
        bool declared = api.StartsWith("Declared"), byName = false;
        if (harmony)
        {
            int ai;
            if (p.Length >= 2 && p[0] == "System.Type" && p[1] == "System.String") { type = a[0]; member = a[1]; ai = 2; }
            else if (p.Length >= 1 && p[0] == "System.String")
            {
                ai = 1;
                // FieldRefAccess<T, F>("field"): the declaring type is the first type argument.
                if (api.EndsWith("FieldRefAccess")) { if (gen.Length == 2) { type = T(gen[0]); member = a[0]; } }
                // "Type:Member": AccessTools splits at the colon and resolves the type by name.
                else if (a[0]?.K == 's' && a[0].S.IndexOf(':') is int ci && ci > 0)
                {
                    type = T(a[0].S.Substring(0, ci));
                    member = new V { K = 's', S = a[0].S.Substring(ci + 1) };
                    byName = true;
                }
            }
            else return (null, null);
            if (what == "method" && p.Length > ai && p[ai] == "System.Type[]") typeArgs = a[ai];
        }
        else
        {
            if (p.Length == 0 || p[0] != "System.String") return (null, null);
            type = self;
            member = a[0];
            int f = p.IndexOf("System.Reflection.BindingFlags");
            declared = f >= 0 && a[f]?.K == 'i' && (a[f].N & 2) != 0; // BindingFlags.DeclaredOnly
            int ti = p.IndexOf("System.Type[]");
            if (what == "method" && ti >= 0) typeArgs = a[ti];
        }
        if (type?.K == 'G') return (null, null);
        if (type?.K != 'T' || type.S.StartsWith("!") || member?.K != 's') { nDynamic++; return (null, null); }
        var tn = FindType(type.S, byName);
        if (tn == null)
        {
            if (Unloaded(type.Asm ?? AsmOf(type.S), Norm(type.S))) { nUnloaded++; return (null, null); }
            nChecked++;
            return ($"type {Norm(type.S)} not found ({label})", null);
        }
        nChecked++;
        Get(tn, out var xh);
        var (x, h) = xh;
        var td = x.R.GetTypeDefinition(h);
        var name = member.S;
        if (what != "method")
        {
            if (!HasMember(x, td, name, declared, what)) return ($"{tn}.{name} {what} not found ({label})", null);
            if (listTargets) okLookup = $"{tn}.{name} ({label})";
            return (null, null);
        }
        var sigs = Overloads(x, td, name, declared, out var open);
        var args = typeArgs?.K == 'a' ? typeArgs.Arr : null;
        if (open || (sigs.Count > 0 && (args == null || sigs.Any(s => Fits(s, args)))))
        {
            if (listTargets) okLookup = $"{tn}.{name}{(args == null ? "" : "(" + string.Join(", ", args.Select(s => s ?? "?")) + ")")} ({label})";
            return (null, null);
        }
        var sl = args == null ? $"{tn}.{name}" : $"{tn}.{name}({string.Join(", ", args.Select(s => s ?? "?"))})";
        return ($"{sl} method not found ({label}){Have(sigs)}", null);
    }
}
