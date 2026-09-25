namespace Bcl
{
    // List<T>._version in miniature: a private field a mod reaches with FieldRefAccess.
    public class Box
    {
        private int _version;

        public int Version => _version;
    }
}
