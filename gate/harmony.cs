// Harmony patch targets that no longer exist, read out of METADATA ONLY: the mod and every
// reference it compiled against are opened with System.Reflection.Metadata, so not one line
// of game code is loaded or run. Compiled in-process by gate/harmony.ps1 through Add-Type;
// System.Reflection.Metadata ships inside the .NET runtime pwsh itself runs on, so there is
// nothing to restore and nothing to build.
//
// Resolution follows Harmony's own PatchTools.GetOriginalMethod: DeclaredMethod /
// DeclaredPropertyGetter / DeclaredPropertySetter / DeclaredConstructor -- DECLARED members
// only, and a name with no argumentTypes over several overloads is Harmony's "Ambiguous
// match". ___field parameters go through AccessTools.Field, which does walk base types.
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

    sealed class Asm { public MetadataReader R; public PEReader Pe; }
    sealed class Target { public string Type, Method; public int? Kind; public string[] Args; public Target Clone() => (Target)MemberwiseClone(); }

    readonly Dictionary<string, (Asm A, TypeDefinitionHandle H)> types = new();
    readonly Dictionary<string, string> source = new();
    readonly SortedSet<string> found = new(StringComparer.Ordinal);
    Asm mod;

    public static string[] Run(string modPath, string[] refPaths, string srcDir, string root)
    {
        var q = new QGateHarmony();
        q.mod = Load(modPath);
        q.Index(q.mod);
        foreach (var p in refPaths) { var a = Load(p); if (a != null) q.Index(a); }
        q.MapSource(srcDir, root);
        q.CheckAttributes();
        q.CheckAccessTools();
        return q.found.ToArray();
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
        foreach (var h in a.R.TypeDefinitions) types.TryAdd(Name(a.R, h), (a, h));
    }

    // Patch class -> "file.cs:line", by declaration in the project's sources: Windows PDBs
    // (DebugType full/pdbonly, what these mods ship) are not readable here, and the class
    // is what the reader has to open. A name declared twice maps to nothing, not a guess.
    void MapSource(string srcDir, string root)
    {
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
        return source.TryGetValue(simple, out var loc) && loc != null ? $"({loc}, {simple}.{method})" : $"({typeName}.{method})";
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
                if (a.Type == "System.Type" && a.Value is string ty) t.Type = ty;
                else if (a.Type == "System.String" && a.Value is string s) strs.Add(s);
                else if (a.Type == "HarmonyLib.MethodType" && a.Value is int k) t.Kind = k;
                else if (a.Type == "System.Type[]" && a.Value is ImmutableArray<CustomAttributeTypedArgument<string>> arr)
                    t.Args = arr.Select(e => Norm((string)e.Value ?? "")).ToArray();
            }
            // (string typeName, string methodName) is the only two-string form.
            if (strs.Count >= 2) { t.Type = strs[0]; t.Method = strs[1]; }
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
                || Has(r, m.GetCustomAttributes(), "HarmonyLib.HarmonyTargetMethod", "HarmonyLib.HarmonyTargetMethods"))) continue;
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
                if (t.Type == null) continue;
                var where = Where(typeName, r.GetString(m.Name));
                var err = Resolve(t, out var ta, out var tdef, out var target, out var label);
                if (err != null) { found.Add($"{err} {where}"); continue; }
                if (kind is "Prefix" or "Postfix" or "Finalizer") CheckParams(m, kind, ta, tdef, target, label, where);
            }
        }
    }

    // null = resolved (or nothing checkable); otherwise the finding.
    string Resolve(Target t, out Asm a, out TypeDefinition td, out MethodDefinition? target, out string label)
    {
        a = null; td = default; target = null;
        var tn = Norm(t.Type);
        label = tn;
        if (!types.TryGetValue(tn, out var x)) return $"type {tn} not found";
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
        var ms = td.GetMethods().Select(r.GetMethodDefinition).Where(m => r.GetString(m.Name) == name).ToList();
        // DeclaredConstructor with no argumentTypes means the parameterless one.
        var args = t.Args ?? (kind == 3 ? Array.Empty<string>() : null);
        if (args != null && kind != 4)
        {
            ms = ms.Where(m =>
            {
                var s = m.DecodeSignature(this, null);
                return s.ParameterTypes.SequenceEqual(args);
            }).ToList();
            label += "(" + string.Join(", ", args) + ")";
        }
        if (ms.Count == 0) return $"{label} not found";
        if (ms.Count > 1) return $"{label} is ambiguous: {ms.Count} overloads and no argumentTypes";
        // Enumerator/Async patch MoveNext, whose parameters are not the method's.
        if (kind is not (5 or 6)) target = ms[0];
        return null;
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
                    found.Add($"{label}: field {n.Substring(3)} not found (parameter {n}) {where}");
                continue;
            }
            if (n.StartsWith("__") || names == null || renames || names.Contains(n)) continue;
            if (Has(r, p.GetCustomAttributes(), "HarmonyLib.HarmonyArgument")) continue;
            var ptype = sig.ParameterTypes[p.SequenceNumber - 1];
            // A pass-through postfix takes the result as its first parameter, under any name.
            if (kind == "Postfix" && p.SequenceNumber == 1 && ptype == sig.ReturnType) continue;
            // A delegate parameter is Harmony's [HarmonyDelegate] injection, not an argument.
            if (IsDelegate(ptype)) continue;
            found.Add($"{label} has no parameter '{n}' {where}");
        }
    }

    bool IsDelegate(string type)
    {
        if (!types.TryGetValue(type, out var x)) return false;
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
            if (bn == null || !types.TryGetValue(bn, out var x)) return true; // base not in the set: cannot say
            a = x.A;
            td = a.R.GetTypeDefinition(x.H);
        }
        return true;
    }

    static readonly Dictionary<ushort, OperandType> Ops = typeof(OpCodes)
        .GetFields(BindingFlags.Public | BindingFlags.Static)
        .Select(f => (OpCode)f.GetValue(null)).ToDictionary(o => (ushort)o.Value, o => o.OperandType);

    // Literal AccessTools.X(typeof(T), "name") calls, read out of the IL as the compiler
    // emits them: ldtoken T; call Type.GetTypeFromHandle; ldstr "name"; ...; call AccessTools.X.
    void CheckAccessTools()
    {
        var r = mod.R;
        foreach (var mh in r.MethodDefinitions)
        {
            var m = r.GetMethodDefinition(mh);
            if (m.RelativeVirtualAddress == 0) continue;
            BlobReader il;
            try { il = mod.Pe.GetMethodBody(m.RelativeVirtualAddress).GetILReader(); }
            catch (BadImageFormatException) { continue; }
            string tok = null, typ = null, str = null;
            while (il.RemainingBytes > 0)
            {
                ushort op = il.ReadByte();
                if (op == 0xFE) op = (ushort)(0xFE00 | il.ReadByte());
                if (!Ops.TryGetValue(op, out var ot)) break;
                switch (ot)
                {
                    case OperandType.InlineNone: break;
                    case OperandType.ShortInlineBrTarget:
                    case OperandType.ShortInlineI:
                    case OperandType.ShortInlineVar: il.ReadByte(); break;
                    case OperandType.InlineVar: il.ReadInt16(); break;
                    case OperandType.InlineI8:
                    case OperandType.InlineR: il.ReadInt64(); break;
                    case OperandType.InlineSwitch: il.Offset += 4 * il.ReadInt32(); break;
                    case OperandType.InlineTok:
                        var th = MetadataTokens.EntityHandle(il.ReadInt32());
                        tok = th.Kind == HandleKind.TypeDefinition ? Name(r, (TypeDefinitionHandle)th)
                            : th.Kind == HandleKind.TypeReference ? Name(r, (TypeReferenceHandle)th) : null;
                        break;
                    case OperandType.InlineString:
                        var s = r.GetUserString((UserStringHandle)MetadataTokens.Handle(il.ReadInt32()));
                        if (typ != null && str == null) str = s;
                        break;
                    case OperandType.InlineMethod:
                        var (parent, name) = Callee(r, MetadataTokens.EntityHandle(il.ReadInt32()));
                        if (parent == "System.Type" && name == "GetTypeFromHandle")
                        {
                            if (str == null && tok != null) typ = tok;
                        }
                        else
                        {
                            if (parent == "HarmonyLib.AccessTools" && typ != null && str != null)
                                CheckAccess(name, typ, str, Where(Name(r, m.GetDeclaringType()), r.GetString(m.Name)));
                            typ = str = null;
                        }
                        tok = null;
                        break;
                    default: il.ReadInt32(); break;
                }
            }
        }
    }

    static (string, string) Callee(MetadataReader r, EntityHandle h)
    {
        if (h.Kind == HandleKind.MethodSpecification) h = r.GetMethodSpecification((MethodSpecificationHandle)h).Method;
        if (h.Kind == HandleKind.MethodDefinition)
        {
            var md = r.GetMethodDefinition((MethodDefinitionHandle)h);
            return (Name(r, md.GetDeclaringType()), r.GetString(md.Name));
        }
        if (h.Kind != HandleKind.MemberReference) return (null, null);
        var mr = r.GetMemberReference((MemberReferenceHandle)h);
        var p = mr.Parent;
        var pn = p.Kind == HandleKind.TypeReference ? Name(r, (TypeReferenceHandle)p)
            : p.Kind == HandleKind.TypeDefinition ? Name(r, (TypeDefinitionHandle)p) : null;
        return (pn, r.GetString(mr.Name));
    }

    void CheckAccess(string api, string type, string member, string where)
    {
        var what = api switch
        {
            "Method" or "DeclaredMethod" => "method",
            "Field" or "DeclaredField" => "field",
            "Property" or "DeclaredProperty" or "PropertyGetter" or "PropertySetter"
                or "DeclaredPropertyGetter" or "DeclaredPropertySetter" => "property",
            _ => null,
        };
        if (what == null || !types.TryGetValue(type, out var x)) return;
        if (!HasMember(x.A, x.A.R.GetTypeDefinition(x.H), member, api.StartsWith("Declared"), what))
            found.Add($"{type}.{member} {what} not found (AccessTools.{api}) {where}");
    }
}
