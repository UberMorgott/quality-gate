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
}
