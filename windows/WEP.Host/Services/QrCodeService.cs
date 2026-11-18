using System.IO;
using System.Windows.Media.Imaging;
using QRCoder;

namespace WEP.Host.Services;

public static class QrCodeService
{
    public static BitmapImage GenerateQrBitmap(string payload)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(payload, QRCodeGenerator.ECCLevel.M);
        var pngQr = new PngByteQRCode(data);
        var pngBytes = pngQr.GetGraphic(10);

        var image = new BitmapImage();
        using var ms = new MemoryStream(pngBytes);
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = ms;
        image.EndInit();
        image.Freeze();
        return image;
    }
}
