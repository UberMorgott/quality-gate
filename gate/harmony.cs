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

    sealed class Asm { public MetadataReader R; public PEReader Pe; }
    sealed class Target { public string Type, Method; public int? Kind; public string[] Args; public bool ByName; public Target Clone() => (Target)MemberwiseClone(); }
    // One value on the symbolic IL stack. K: 'T' a type (S = name, Asm = its assembly),
    // 's' a string, 'i' an int, '0' null, 'a' a Type[] (Arr; a null element is not known).
    // Anything else is a null V.
    sealed class V { public char K; public string S, Asm; public int N; public string[] Arr; }
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
    SortedSet<string> fails, probes;
    // -Why / -Targets: every target that DID resolve, so a reviewer can confirm a specific new
    // patch by name instead of inferring it from a count that went up.
    List<string> oks;
    bool listTargets;
    // The reflection lookup Lookup() just resolved; Scan appends the source location.
    string okLookup;
    // Failed lookups whose result was stored (local/field): a probe if it is null-checked where read.
    List<(string Msg, string Sink)> stored;
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
        foreach (var p in refPaths) { var a = Load(p); if (a != null) q.Index(a); }
        q.MapSource(srcDir, root);
        var outp = new List<string>();
        const string probe = " -- its result is null-checked: a version probe with a fallback";
        for (int i = 0; i < asms.Length; i++)
        {
            if (asms[i] == null) continue;
            q.Check(asms[i], i < own);
            var file = Path.GetFileName(mods[i]);
            var pre = i < own ? "" : file + ": ";
            outp.AddRange(q.fails.Select(f => i < own ? f : "[WARN] harmony: " + pre + f));
            outp.AddRange(q.probes.Select(p => "[WARN] harmony: " + pre + p + probe));
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
            var pe = new PEReader(ImmutableArray.Create(File.ReadAllBytes(path)));
            return pe.HasMetadata ? new Asm { Pe = pe, R = pe.GetMetadataReader() } : null;
        }
        catch (Exception) { return null; }
    }

    void Index(Asm a)
    {
        var r = a.R;
        if (r.IsAssembly) loaded.Add(r.GetString(r.GetAssemblyDefinition().Name));
        foreach (var h in r.TypeDefinitions) types.TryAdd(Name(r, h), (a, h));
        foreach (var h in r.ExportedTypes)
        {
            var e = r.GetExportedType(h);
            var ns = r.GetString(e.Namespace);
            if (e.IsForwarder) forwarded.Add(ns.Length == 0 ? r.GetString(e.Name) : ns + "." + r.GetString(e.Name));
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
        oks = new();
        stored = new();
        checkedSinks = new();
        nChecked = nDynamic = nComputed = nUnloaded = 0;
        CheckAttributes();
        CheckIL();
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
                    fails.Add($"{label}: field {n.Substring(3)} not found (parameter {n}) {where}");
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
        public Ins(int off, OpCode op, int arg) { Off = off; Op = op; Arg = arg; }
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
                    for (int k = 0; k < n; k++) targets.Add(end + il.ReadInt32());
                    break;
                default: arg = il.ReadInt32(); break;
            }
            list.Add(new Ins(off, op, arg));
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
        foreach (var er in body.ExceptionRegions)
        {
            targets.Add(er.HandlerOffset);
            if (er.Kind == ExceptionRegionKind.Filter) targets.Add(er.FilterOffset);
        }
        var locKey = "L" + MetadataTokens.GetRowNumber(mh) + ":";
        var st = new List<V>();
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
            // Where a stored lookup result is read back and null-checked.
            int li = Loc(x, false);
            if (li >= 0 && NullCheckAt(ins, i + 1)) checkedSinks.Add(locKey + li);
            if ((op == OpCodes.Ldfld || op == OpCodes.Ldsfld) && NullCheckAt(ins, i + 1)) checkedSinks.Add("F" + x.Arg);

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
            if (op == OpCodes.Stelem_Ref)
            {
                var val = Pop(); var idx = Pop(); var arr = Pop();
                if (arr?.K == 'a' && idx?.K == 'i' && idx.N >= 0 && idx.N < arr.Arr.Length && val?.K == 'T') arr.Arr[idx.N] = val.S;
                continue;
            }
            if (op == OpCodes.Ldsfld && FieldName(r, Tok(x.Arg)) == "System.Type::EmptyTypes") { st.Add(new V { K = 'a', Arr = Array.Empty<string>() }); continue; }
            if (op == OpCodes.Call || op == OpCodes.Callvirt || op == OpCodes.Newobj)
            {
                var (parent, name, sig, gen) = Callee(r, Tok(x.Arg));
                if (sig == null) { st.Clear(); continue; }
                var p = sig.Value.ParameterTypes;
                var a = new V[p.Length];
                for (int k = p.Length - 1; k >= 0; k--) a[k] = Pop();
                var self = sig.Value.Header.IsInstance && op != OpCodes.Newobj ? Pop() : null;
                V ret = null;
                if (parent == "System.Type" && name == "GetTypeFromHandle") ret = a[0];
                else if (parent == "System.Type" && name == "MakeByRefType") ret = self; // byref is dropped from every name
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
                        if (NullCheckAt(ins, i + 1)) probes.Add(msg);
                        else if (i + 1 < ins.Count && Sink(ins[i + 1], locKey) is string sink) stored.Add((msg, sink));
                        else fails.Add(msg);
                    }
                }
                if (op == OpCodes.Newobj || sig.Value.ReturnType != "System.Void") st.Add(ret);
                continue;
            }
            if (op.FlowControl is FlowControl.Branch or FlowControl.Return or FlowControl.Throw || op == OpCodes.Calli) { st.Clear(); continue; }
            for (int k = Count(op.StackBehaviourPop); k > 0; k--) Pop();
            for (int k = Count(op.StackBehaviourPush); k > 0; k--) st.Add(null);
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
        if (harmony && api == "TypeByName" && p.Length == 1)
        {
            if (a[0]?.K != 's') { nDynamic++; return (null, null); }
            var hit = FindType(a[0].S, true);
            if (hit == null && Unloaded(AsmOf(a[0].S), Norm(a[0].S))) { nUnloaded++; return (null, null); }
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
