namespace Tests;

/// <summary>A Fact and a Theory -- replace with tests of the project under test.</summary>
public class SampleTests
{
    /// <summary>A Fact runs once.</summary>
    [Fact]
    public void Adds() => Assert.Equal(4, 2 + 2);

    /// <summary>A Theory runs once per data row.</summary>
    [Theory]
    [InlineData("a", 1)]
    [InlineData("abc", 3)]
    public void Measures(string text, int length) => Assert.Equal(length, text.Length);
}