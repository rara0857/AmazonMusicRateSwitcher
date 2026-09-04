using System.Text;
using System.Text.Json;

namespace AmazonMusicRateSwitcher.Gui;

internal enum BackendMessageKind
{
    Log,
    Error,
    Exclusive,
    Format,
    Track,
    AutoTestSummary
}

internal sealed record TrackMetadata(
    string Asin,
    string Title,
    string Artist,
    string Album,
    string ArtworkUrl);

internal sealed record BackendMessage(
    BackendMessageKind Kind,
    string Text = "",
    bool Active = false,
    string Asin = "",
    int Bits = 0,
    int RateHz = 0,
    TrackMetadata? Metadata = null);

internal static class BackendMessageParser
{
    private const string FormatPrefix = "@@AMRS_FORMAT@@";
    private const string TrackBase64Prefix = "@@AMRS_TRACK_B64@@";
    private const string TrackLegacyPrefix = "@@AMRS_TRACK@@";
    private const string AutoTestSummaryPrefix = "@@AMRS_AUTOTEST_SUMMARY_B64@@";
    private const string ExclusivePrefix = "@@AMRS_EXCLUSIVE@@";
    private const string ErrorPrefix = "@@AMRS_ERROR_B64@@";

    public static BackendMessage Parse(string text)
    {
        if (text.StartsWith(ExclusivePrefix, StringComparison.Ordinal))
        {
            var active = string.Equals(
                text[ExclusivePrefix.Length..],
                "ON",
                StringComparison.OrdinalIgnoreCase);
            return new BackendMessage(BackendMessageKind.Exclusive, Active: active);
        }

        if (TryDecodeBase64(text, ErrorPrefix, out var error))
            return new BackendMessage(BackendMessageKind.Error, Text: error);

        if (TryDecodeBase64(text, AutoTestSummaryPrefix, out var summary))
            return new BackendMessage(BackendMessageKind.AutoTestSummary, Text: summary);

        if (text.StartsWith(FormatPrefix, StringComparison.Ordinal))
        {
            var parts = text[FormatPrefix.Length..].Split('|');
            if (parts.Length == 3 &&
                int.TryParse(parts[1], out var bits) &&
                int.TryParse(parts[2], out var rateHz))
            {
                return new BackendMessage(
                    BackendMessageKind.Format,
                    Asin: parts[0],
                    Bits: bits,
                    RateHz: rateHz);
            }
        }

        if (text.StartsWith(TrackBase64Prefix, StringComparison.Ordinal) ||
            text.StartsWith(TrackLegacyPrefix, StringComparison.Ordinal))
        {
            try
            {
                var json = text.StartsWith(TrackBase64Prefix, StringComparison.Ordinal)
                    ? Encoding.UTF8.GetString(Convert.FromBase64String(text[TrackBase64Prefix.Length..]))
                    : text[TrackLegacyPrefix.Length..];
                var metadata = JsonSerializer.Deserialize<TrackMetadata>(
                    json,
                    new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
                if (metadata is not null)
                    return new BackendMessage(BackendMessageKind.Track, Metadata: metadata);
            }
            catch
            {
                // Metadata is decorative. Leave malformed payloads as ordinary
                // log lines so playback control remains unaffected.
            }
        }

        return new BackendMessage(BackendMessageKind.Log, Text: text);
    }

    private static bool TryDecodeBase64(string text, string prefix, out string value)
    {
        value = string.Empty;
        if (!text.StartsWith(prefix, StringComparison.Ordinal))
            return false;

        try
        {
            value = Encoding.UTF8.GetString(Convert.FromBase64String(text[prefix.Length..]));
            return true;
        }
        catch
        {
            return false;
        }
    }
}
