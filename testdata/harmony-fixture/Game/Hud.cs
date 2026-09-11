public class Unit { }

public interface IDamageable { }

public class Player : Unit, IDamageable { }

public class Hud
{
    private float m_health;

    public float Health => m_health;

    public void UpdateHealth(float dt)
    {
        m_health += dt;
    }

    public void Damage(Unit target, float amount) { }

    public void Hit(IDamageable target) { }

    public static T Spawn<T>(T original, float delay) => original;
}
