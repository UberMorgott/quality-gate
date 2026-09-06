namespace Fixture;

/// <summary>Greets whoever is passed in.</summary>
public static class Greeter
{
    /// <summary>Returns a greeting for <paramref name="name"/>.</summary>
    public static string Greet(string name)
    {
        return $"Hello, {name}!";
    }
}
