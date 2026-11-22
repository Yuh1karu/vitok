package __APP_ID__;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.net.Uri;
import android.os.Build;
import android.provider.Settings;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.concurrent.atomic.AtomicInteger;

@CapacitorPlugin(
    name = "VitokUpdater",
    permissions = {
        @Permission(strings = {Manifest.permission.READ_MEDIA_IMAGES}, alias = "media33"),
        @Permission(strings = {Manifest.permission.READ_EXTERNAL_STORAGE}, alias = "media")
    }
)
public class VitokUpdater extends Plugin {
    private final AtomicInteger prog = new AtomicInteger(0);

    private String galleryAlias() {
        return Build.VERSION.SDK_INT >= 33 ? "media33" : "media";
    }

    /** Разрешение на галерею (системный диалог). */
    @PluginMethod
    public void requestGallery(PluginCall call) {
        if (getPermissionState(galleryAlias()) == PermissionState.GRANTED) {
            JSObject o = new JSObject();
            o.put("granted", true);
            call.resolve(o);
            return;
        }
        requestPermissionForAlias(galleryAlias(), call, "galleryCb");
    }

    @PermissionCallback
    private void galleryCb(PluginCall call) {
        JSObject o = new JSObject();
        o.put("granted", getPermissionState(galleryAlias()) == PermissionState.GRANTED);
        call.resolve(o);
    }

    /** Открывает ссылку (донат) во внешнем браузере. */
    @PluginMethod
    public void openUrl(PluginCall call) {
        String u = call.getString("url");
        if (u == null || !(u.startsWith("https://") || u.startsWith("http://"))) {
            call.reject("bad url");
            return;
        }
        Intent i = new Intent(Intent.ACTION_VIEW, Uri.parse(u));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        getContext().startActivity(i);
        call.resolve();
    }

    @PluginMethod
    public void progress(PluginCall call) {
        JSObject o = new JSObject();
        o.put("p", prog.get());
        call.resolve(o);
    }

    /** Скачивает APK по ссылке и запускает установку поверх текущего приложения. */
    @PluginMethod
    public void install(final PluginCall call) {
        final String url = call.getString("url");
        if (url == null || url.isEmpty()) {
            call.reject("no url");
            return;
        }
        final Context ctx = getContext();
        if (Build.VERSION.SDK_INT >= 26 && !ctx.getPackageManager().canRequestPackageInstalls()) {
            Intent i = new Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:" + ctx.getPackageName()));
            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
            ctx.startActivity(i);
            call.reject("need_permission");
            return;
        }
        prog.set(0);
        new Thread(() -> {
            HttpURLConnection c = null;
            try {
                File dir = new File(ctx.getCacheDir(), "upd");
                dir.mkdirs();
                File f = new File(dir, "Vitok-update.apk");
                if (f.exists()) f.delete();

                c = (HttpURLConnection) new URL(url).openConnection();
                c.setInstanceFollowRedirects(true);
                c.setConnectTimeout(15000);
                c.setReadTimeout(30000);
                c.setRequestProperty("User-Agent", "Vitok-Updater");
                if (c.getResponseCode() != 200) throw new Exception("HTTP " + c.getResponseCode());
                long total = c.getContentLengthLong();
                long done = 0;
                try (InputStream in = c.getInputStream(); FileOutputStream out = new FileOutputStream(f)) {
                    byte[] buf = new byte[32768];
                    int n;
                    while ((n = in.read(buf)) > 0) {
                        out.write(buf, 0, n);
                        done += n;
                        if (total > 0) prog.set((int) (done * 100 / total));
                    }
                }
                prog.set(100);

                // Проверяем, что это наш APK, иначе система скажет «конфликт пакета»
                PackageInfo pi = ctx.getPackageManager().getPackageArchiveInfo(f.getAbsolutePath(), 0);
                if (pi == null) throw new Exception("Файл повреждён");
                if (!ctx.getPackageName().equals(pi.packageName)) throw new Exception("Другой id приложения");

                Uri uri = FileProvider.getUriForFile(ctx, ctx.getPackageName() + ".fileprovider", f);
                Intent i = new Intent(Intent.ACTION_VIEW);
                i.setDataAndType(uri, "application/vnd.android.package-archive");
                i.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_ACTIVITY_NEW_TASK);
                ctx.startActivity(i);
                call.resolve();
            } catch (Exception e) {
                call.reject(String.valueOf(e.getMessage()));
            } finally {
                if (c != null) c.disconnect();
            }
        }).start();
    }
}
