public class Hud
{
    private float m_health;

    public float Health => m_health;

    public void UpdateHealth(float dt)
    {
        m_health += dt;
    }
}
