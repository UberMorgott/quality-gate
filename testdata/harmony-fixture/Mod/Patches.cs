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

public static class Lookups
{
    public static object Valid() => AccessTools.Field(typeof(Hud), "m_health");

    public static object Dangling() => AccessTools.Method(typeof(Hud), "UpdateFood");
}
