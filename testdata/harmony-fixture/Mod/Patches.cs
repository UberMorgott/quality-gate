using System;
using System.Collections;
using System.Reflection;
using HarmonyLib;

namespace Fixture;

// Valid: the method, its parameter, the private field and the property getter all exist.
[HarmonyPatch(typeof(Hud), "UpdateHealth")]
public static class HealthPatch
{
    public static void Postfix(Hud __instance, float dt, float ___m_health) { }
}

[HarmonyPatch(typeof(Hud), "Health", MethodType.Getter)]
public static class HealthGetterPatch
{
    public static void Postfix() { }
}

// Valid the way reflection's default binder matches argumentTypes: a Player is a Unit.
[HarmonyPatch(typeof(Hud), "Damage", new[] { typeof(Player), typeof(float) })]
public static class AssignablePatch
{
    public static void Prefix(Unit target) { }
}

// Dangling: every one of these compiles, and every one fails at runtime.
[HarmonyPatch(typeof(Hud), "UpdateStatusEffects")]
public static class StatusPatch
{
    public static void Postfix() { }
}

[HarmonyPatch(typeof(Hud), "UpdateHealth")]
public static class StaminaPatch
{
    public static void Prefix(float ___m_stamina, float delta) { }
}

// Right number of arguments, wrong types.
[HarmonyPatch(typeof(Hud), "Damage", new[] { typeof(Unit), typeof(string) })]
public static class WrongTypesPatch
{
    public static void Prefix() { }
}

// Wrong number of arguments: the target gained a parameter (Valheim 1.0.7 Inventory.AddItem).
[HarmonyPatch(typeof(Hud), "Damage", new[] { typeof(Unit) })]
public static class ArityPatch
{
    public static void Prefix() { }
}

// Computed at runtime: counted as not checkable, never guessed at.
[HarmonyPatch]
public static class ComputedPatch
{
    public static MethodBase TargetMethod() => AccessTools.Method(typeof(Hud), Pick());

    public static string Pick() => "UpdateHealth";

    public static void Postfix() { }
}

// An optional plugin's target: Prepare() false skips the patch, TargetMethod is never called (#215).
[HarmonyPatch]
public static class OptionalPatch
{
    public static bool Prepare() => AccessTools.TypeByName("SoftDep.Optional") != null;

    public static MethodBase TargetMethod() => AccessTools.Method(AccessTools.TypeByName("SoftDep.Optional"), "Run");

    public static void Postfix() { }
}

// Prepare guards a different type: the TargetMethod's own missing type still fails.
[HarmonyPatch]
public static class MisguardedPatch
{
    public static bool Prepare() => AccessTools.TypeByName("SoftDep.Guard") != null;

    public static MethodBase TargetMethod() => AccessTools.Method(AccessTools.TypeByName("SoftDep.Unguarded"), "Run");

    public static void Postfix() { }
}

public static class Lookups
{
    public static object Valid() => AccessTools.Field(typeof(Hud), "m_health");

    public static object ValidAssignable() => AccessTools.Method(typeof(Hud), "Damage", new[] { typeof(Player), typeof(float) });

    public static object ValidInterface() => typeof(Hud).GetMethod("Hit", new[] { typeof(Player) });

    public static object ValidGeneric() => typeof(Hud).GetMethod("Spawn", new[] { typeof(Player), typeof(float) });

    public static object ValidColon() => AccessTools.Method("Hud:UpdateHealth");

    public static object ValidTypeByName() => AccessTools.TypeByName("Hud");

    public static object Dangling() => AccessTools.Method(typeof(Hud), "UpdateFood");

    public static object DanglingTypes() => AccessTools.Method(typeof(Hud), "Damage", new[] { typeof(string), typeof(float) });

    public static object DanglingGetMethod() => typeof(Hud).GetMethod("UpdateArmor");

    public static object DanglingColon() => AccessTools.Method("Hud:UpdateStamina");

    public static object DanglingTypeByName() => AccessTools.TypeByName("Minimap");

    // Version probes: looked up, null-checked, a fallback taken. Warnings, not failures.
    static readonly MethodInfo OldApi = typeof(Hud).GetMethod("UpdateMana");

    public static bool HasOldApi() => OldApi != null;

    public static object Probe() => AccessTools.Method(typeof(Hud), "UpdateShield") ?? AccessTools.Method(typeof(Hud), "UpdateHealth");

    // A soft dependency's type, its null followed to the check (#204, #212): warnings.
    public static object ProbeThroughField() => AccessTools.Field(AccessTools.TypeByName("SoftDep.Sets"), "All")?.GetValue(null);

    public static object ProbeThroughHelper() => Find(AccessTools.TypeByName("SoftDep.Assistant"), "Nearby");

    public static object ProbeStoredHelper()
    {
        var t = AccessTools.TypeByName("SoftDep.Stopwatch");
        return Find(t, "Get") ?? Find(t, "Get2");
    }

    static MethodInfo Find(Type type, string name) => type == null ? null : AccessTools.Method(type, name);

    // Stored local/field passed to AccessTools.Field whose result is null-checked, and getters
    // returning TypeByName whose callers null-check the return value (#247): warnings.
    public static string ProbeStoredField()
    {
        var t = AccessTools.TypeByName("SoftDep.IdleLod");
        if (!(AccessTools.Field(t, "s_state")?.GetValue(null) is IDictionary _)) return "na";
        return "ok";
    }

    public static bool ProbeStoredFieldIs()
    {
        var t = AccessTools.TypeByName("SoftDep.IdleIs");
        return ((object)AccessTools.Field(t, "s_state")) is FieldInfo;
    }

    static Type SkirtRigType => AccessTools.TypeByName("SoftDep.SkirtRig");

    public static object ProbeGetterField() => AccessTools.Field(SkirtRigType, "x")?.GetValue(null);

    static Type SkirtLocalType => AccessTools.TypeByName("SoftDep.SkirtLocal");

    public static bool ProbeGetterLocal()
    {
        var t = SkirtLocalType;
        return t != null;
    }

    static Type GuardThenDerefGetter => AccessTools.TypeByName("SoftDep.GuardThenDeref");

    public static string ProbeGuardThenDeref()
    {
        var t = GuardThenDerefGetter;
        if (t == null) return "";
        return t.FullName;
    }

    // Non-null fallback helper (`t == null ? typeof(string) : t`) makes caller deref safe: probe.
    static Type FallbackHelperGetter => AccessTools.TypeByName("SoftDep.HelperNonNullFallback");
    static Type FallbackNonNull(Type t) => t == null ? typeof(string) : t;
    public static string ProbeNonNullFallback() => FallbackNonNull(FallbackHelperGetter).FullName;

    // The same nulls never checked: failures.
    public static object DanglingThroughField() => AccessTools.Field(AccessTools.TypeByName("SoftDep.Unchecked"), "All").GetValue(null);

    public static object DanglingThroughHelper() => Use(AccessTools.TypeByName("SoftDep.Used"));

    public static object DanglingDeref() => AccessTools.TypeByName("SoftDep.Deref").GetMethod("Run");

    public static object DanglingStoredField()
    {
        var t = AccessTools.TypeByName("SoftDep.IdleBad");
        return AccessTools.Field(t, "s_state").GetValue(null);
    }

    static Type BadGetter => AccessTools.TypeByName("SoftDep.SkirtBad");

    public static object DanglingGetter() => AccessTools.Field(BadGetter, "x").GetValue(null);

    static Type UnusedGetter => AccessTools.TypeByName("SoftDep.Unused");

    static object Use(Type type) => type.Name;
}
