using System;
using System.Reflection;

namespace HarmonyLib
{
    public enum MethodType { Normal, Getter, Setter, Constructor, StaticConstructor, Enumerator }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true)]
    public class HarmonyPatch : Attribute
    {
        public HarmonyPatch() { }

        public HarmonyPatch(Type declaringType, string methodName) { }

        public HarmonyPatch(Type declaringType, string methodName, MethodType methodType) { }

        public HarmonyPatch(Type declaringType, string methodName, params Type[] argumentTypes) { }
    }

    // The real signatures (Harmony 2): parameters/generics default to null.
    public static class AccessTools
    {
        public static MethodInfo Method(Type type, string name, Type[] parameters = null, Type[] generics = null) => null;

        public static MethodInfo Method(string typeColonName, Type[] parameters = null, Type[] generics = null) => null;

        public static FieldInfo Field(Type type, string name) => null;

        public static Type TypeByName(string name) => null;
    }
}
