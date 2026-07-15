using System.Runtime.InteropServices;

namespace StickShift.Os;

// Windows OS-layer INJECTION (docs/WINDOWS.md step 2) — port of macOS Inject.m's keystroke
// primitives. Uses SendInput with KEYEVENTF_UNICODE for text: it types the literal character
// regardless of keyboard layout, so Mark's "refuse characters the active layout cannot produce"
// concern is moot for our injection-safe ASCII charset (Config.IsInjectionSafe gates the values
// upstream). Synthetic input goes to the FOREGROUND window, so the caller must ensure the target
// owns foreground/key focus first (WindowFocus). Technique borrowed from the validated POC
// (stickshift-windows GearEngine), including the x64 INPUT-sizing gotcha.
public static class Injector
{
    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] inputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;   // largest member — INPUT must be sized to it
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }

    // On x64, INPUT must be sized to the largest union member (MOUSEINPUT) or SendInput returns 0
    // and injects nothing — the documented POC gotcha. Keeping MOUSEINPUT in the union guarantees it.
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }

    const uint INPUT_KEYBOARD = 1;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint KEYEVENTF_UNICODE = 0x0004;
    const ushort VK_RETURN = 0x0D, VK_ESCAPE = 0x1B, VK_UP = 0x26, VK_DOWN = 0x28, VK_BACK = 0x08;

    // Fail-closed layout check. With Unicode injection every BMP character is injectable, so the
    // only refusal is a surrogate pair (never present in our injection-safe ASCII values). Kept as
    // a named gate so call sites read like Mark's Inject.canTypeText.
    public static bool CanTypeText(string? text)
    {
        if (string.IsNullOrEmpty(text)) return false;
        foreach (char ch in text) if (char.IsSurrogate(ch)) return false;
        return true;
    }

    public static void TypeText(string text)
    {
        var inputs = new List<INPUT>(text.Length * 2);
        foreach (char ch in text)
        {
            inputs.Add(UnicodeKey(ch, keyUp: false));
            inputs.Add(UnicodeKey(ch, keyUp: true));
        }
        Send(inputs.ToArray());
    }

    public static void PressReturn() => PressVirtualKey(VK_RETURN);
    public static void PressEscape() => PressVirtualKey(VK_ESCAPE);
    public static void PressBackspace() => PressVirtualKey(VK_BACK);
    public static void PressDown() => PressVirtualKey(VK_DOWN);
    public static void PressUp() => PressVirtualKey(VK_UP);

    // Press a single digit key (0..9) — used for codex picker row selection.
    public static void PressDigit(int digit)
    {
        if (digit is < 0 or > 9) return;
        PressVirtualKey((ushort)(0x30 + digit)); // VK_0..VK_9
    }

    static INPUT UnicodeKey(char ch, bool keyUp) => new()
    {
        type = INPUT_KEYBOARD,
        U = { ki = new KEYBDINPUT { wVk = 0, wScan = ch, dwFlags = KEYEVENTF_UNICODE | (keyUp ? KEYEVENTF_KEYUP : 0) } },
    };

    static void PressVirtualKey(ushort virtualKey) => Send(new[]
    {
        new INPUT { type = INPUT_KEYBOARD, U = { ki = new KEYBDINPUT { wVk = virtualKey } } },
        new INPUT { type = INPUT_KEYBOARD, U = { ki = new KEYBDINPUT { wVk = virtualKey, dwFlags = KEYEVENTF_KEYUP } } },
    });

    static void Send(INPUT[] inputs) => SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
}
