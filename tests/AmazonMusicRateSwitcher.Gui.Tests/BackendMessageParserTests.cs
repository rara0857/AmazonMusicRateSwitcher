using System.Text;

namespace AmazonMusicRateSwitcher.Gui.Tests;

[TestClass]
public sealed class BackendMessageParserTests
{
    [TestMethod]
    public void Parse_ExclusiveStatus_ReturnsTypedEvent()
    {
        var message = BackendMessageParser.Parse("@@AMRS_EXCLUSIVE@@ON");

        Assert.AreEqual(BackendMessageKind.Exclusive, message.Kind);
        Assert.IsTrue(message.Active);
    }

    [TestMethod]
    public void Parse_Format_ReturnsAsinAndFormat()
    {
        var message = BackendMessageParser.Parse("@@AMRS_FORMAT@@B012345678|24|96000");

        Assert.AreEqual(BackendMessageKind.Format, message.Kind);
        Assert.AreEqual("B012345678", message.Asin);
        Assert.AreEqual(24, message.Bits);
        Assert.AreEqual(96000, message.RateHz);
    }

    [TestMethod]
    public void Parse_Base64Track_PreservesUnicodeMetadata()
    {
        const string json = "{\"asin\":\"B012345678\",\"title\":\"晚餐歌\",\"artist\":\"測試\",\"album\":\"專輯\",\"artworkUrl\":\"https://example.test/cover.jpg\"}";
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(json));

        var message = BackendMessageParser.Parse("@@AMRS_TRACK_B64@@" + payload);

        Assert.AreEqual(BackendMessageKind.Track, message.Kind);
        Assert.IsNotNull(message.Metadata);
        Assert.AreEqual("晚餐歌", message.Metadata.Title);
        Assert.AreEqual("測試", message.Metadata.Artist);
    }

    [TestMethod]
    public void Parse_Base64Error_ReturnsTypedError()
    {
        const string error = "Amazon renderer is not ready";
        var payload = Convert.ToBase64String(Encoding.UTF8.GetBytes(error));

        var message = BackendMessageParser.Parse("@@AMRS_ERROR_B64@@" + payload);

        Assert.AreEqual(BackendMessageKind.Error, message.Kind);
        Assert.AreEqual(error, message.Text);
    }

    [TestMethod]
    public void Parse_MalformedProtocolLine_FallsBackToLog()
    {
        const string line = "@@AMRS_FORMAT@@missing-fields";

        var message = BackendMessageParser.Parse(line);

        Assert.AreEqual(BackendMessageKind.Log, message.Kind);
        Assert.AreEqual(line, message.Text);
    }
}
