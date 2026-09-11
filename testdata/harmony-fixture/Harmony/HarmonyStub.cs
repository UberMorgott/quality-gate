using System;
using System.Reflection;

namespace HarmonyLib
{
    public enum MethodType { Normal, Getter, Setter, Constructor, StaticConstructor, Enumerator }

    [AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = true)]
    public class HarmonyPatch : Attribute
    {
        public HarmonyPatch(Type declaringType, string methodName) { }

        public HarmonyPatch(Type declaringType, string methodName, MethodType methodType) { }
    }

    public static class AccessTools
    {
        public static MethodInfo Method(Type type, string name) => null;

        public static FieldInfo Field(Type type, string name) => null;
    }
}
