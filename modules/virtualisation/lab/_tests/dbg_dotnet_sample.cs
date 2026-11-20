// The assembly guest-dbg's .NET places are tested on, and with --il what reflection says each tested method's IL is.
using System;
using System.Reflection;

namespace Lab
{
    public static class Sample
    {
        public static int Add(int a, int b) { return a + b; }

        public static int Add(int a, int b, int c) { return a + b + c; }

        public static string Name(string text)
        {
            try { return text.Trim(); }
            catch (ArgumentException) { return ""; }
        }

        public static class Outer
        {
            public static class Inner
            {
                public static int Twice(int x) { return x * 2; }
            }
        }
    }

    public static class Dump
    {
        static void Show(Type type, string place)
        {
            foreach (MethodInfo method in type.GetMethods(BindingFlags.Public | BindingFlags.Static | BindingFlags.DeclaredOnly))
            {
                Console.WriteLine(place + "::" + method.Name + "/" + method.GetParameters().Length + " "
                                  + BitConverter.ToString(method.GetMethodBody().GetILAsByteArray()).Replace("-", ""));
            }
        }

        public static void Main()
        {
            Show(typeof(Sample), "Lab.Sample");
            Show(typeof(Sample.Outer.Inner), "Lab.Sample+Outer+Inner");
        }
    }
}
