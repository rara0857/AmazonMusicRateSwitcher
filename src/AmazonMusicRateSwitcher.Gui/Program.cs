namespace AmazonMusicRateSwitcher.Gui;

internal static class Program
{
    private const string GuiMutexName = "Local\\AmazonMusicRateSwitcher.Gui.v1";

    [STAThread]
    private static void Main()
    {
        using var instanceMutex = new Mutex(true, GuiMutexName, out var createdNew);
        if (!createdNew)
        {
            MessageBox.Show(
                "Amazon Music Rate Switcher is already open.",
                "Amazon Music Rate Switcher",
                MessageBoxButtons.OK,
                MessageBoxIcon.Information);
            return;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm(ProjectRoot.Find()));
    }
}
