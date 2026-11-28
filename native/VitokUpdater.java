package __APP_ID__;

import android.Manifest;
import android.app.AppOpsManager;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.usage.UsageEvents;
import android.app.usage.UsageStatsManager;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.os.PowerManager;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import com.getcapacitor.JSArray;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
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
    public void setWidget(PluginCall call) {
        try {
            android.content.SharedPreferences sp = getContext().getSharedPreferences("vitok_widget", Context.MODE_PRIVATE);
            sp.edit()
                .putInt("streak", call.getInt("streak", 0))
                .putInt("sparks", call.getInt("sparks", 0))
                .putInt("min", call.getInt("min", 0))
                .putInt("done", call.getInt("done", 0))
                .putInt("total", call.getInt("total", 0))
                .apply();
            VitokWidget.refresh(getContext());
        } catch (Exception e) {
        }
        call.resolve();
    }

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

    /** Запоминает репозиторий и включает фоновую проверку новых релизов (раз в ~30 минут). */
    @PluginMethod
    public void watchUpdates(PluginCall call) {
        try {
            String repo = call.getString("repo", "");
            if (repo == null || !repo.matches("[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")) {
                call.reject("bad repo");
                return;
            }
            getContext().getSharedPreferences(VitokUpdWorker.PREFS, Context.MODE_PRIVATE).edit().putString("repo", repo).apply();
            androidx.work.Constraints cons = new androidx.work.Constraints.Builder()
                .setRequiredNetworkType(androidx.work.NetworkType.CONNECTED).build();
            androidx.work.PeriodicWorkRequest req = new androidx.work.PeriodicWorkRequest.Builder(
                VitokUpdWorker.class, 30, java.util.concurrent.TimeUnit.MINUTES).setConstraints(cons).build();
            androidx.work.WorkManager.getInstance(getContext()).enqueueUniquePeriodicWork(
                "vitok_upd", androidx.work.ExistingPeriodicWorkPolicy.KEEP, req);
        } catch (Exception e) {
        }
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

    // ===== 2.8: уведомления с таймером, контроль выхода из приложения, разрешения =====
    private static final String TCH = "vitok_timer";

    /** Постоянное уведомление с секундомером (сон / таймер). countdown=true: обратный отсчёт до when. */
    @PluginMethod
    public void showTimer(PluginCall call) {
        Context c = getContext();
        NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
        if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(TCH) == null) {
            NotificationChannel ch = new NotificationChannel(TCH, "Таймер и сон", NotificationManager.IMPORTANCE_LOW);
            ch.setSound(null, null);
            ch.enableVibration(false);
            nm.createNotificationChannel(ch);
        }
        int id = call.getInt("id", 7001);
        Double w = call.getDouble("when");
        long when = w == null ? System.currentTimeMillis() : w.longValue();
        boolean down = Boolean.TRUE.equals(call.getBoolean("countdown", false));
        int icon = c.getResources().getIdentifier("ic_stat_icon_config_sample", "drawable", c.getPackageName());
        if (icon == 0) icon = c.getApplicationInfo().icon;
        Intent li = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
        PendingIntent pi = li == null ? null
            : PendingIntent.getActivity(c, 0, li, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        NotificationCompat.Builder b = new NotificationCompat.Builder(c, TCH)
            .setSmallIcon(icon)
            .setContentTitle(call.getString("title", "Виток"))
            .setContentText(call.getString("text", ""))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(true)
            .setWhen(when)
            .setUsesChronometer(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS);
        if (pi != null) b.setContentIntent(pi);
        if (Build.VERSION.SDK_INT >= 24) b.setChronometerCountDown(down);
        try {
            nm.notify(id, b.build());
            call.resolve();
        } catch (Exception e) {
            call.reject(String.valueOf(e.getMessage()));
        }
    }

    @PluginMethod
    public void hideTimer(PluginCall call) {
        NotificationManager nm = (NotificationManager) getContext().getSystemService(Context.NOTIFICATION_SERVICE);
        nm.cancel(call.getInt("id", 7001));
        call.resolve();
    }

    private boolean usageGranted() {
        Context c = getContext();
        AppOpsManager ao = (AppOpsManager) c.getSystemService(Context.APP_OPS_SERVICE);
        if (ao == null) return false;
        int m = Build.VERSION.SDK_INT >= 29
            ? ao.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), c.getPackageName())
            : ao.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, android.os.Process.myUid(), c.getPackageName());
        return m == AppOpsManager.MODE_ALLOWED;
    }

    @PluginMethod
    public void permState(PluginCall call) {
        Context c = getContext();
        JSObject o = new JSObject();
        o.put("notif", NotificationManagerCompat.from(c).areNotificationsEnabled());
        o.put("usage", usageGranted());
        o.put("gallery", getPermissionState(galleryAlias()) == PermissionState.GRANTED);
        PowerManager pm = (PowerManager) c.getSystemService(Context.POWER_SERVICE);
        o.put("battery", pm != null && pm.isIgnoringBatteryOptimizations(c.getPackageName()));
        call.resolve(o);
    }

    /** kind: usage | notif | battery | app */
    @PluginMethod
    public void openSettings(PluginCall call) {
        String k = call.getString("kind", "app");
        Context c = getContext();
        Intent i;
        if ("usage".equals(k)) i = new Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS);
        else if ("notif".equals(k)) i = new Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, c.getPackageName());
        else if ("battery".equals(k)) i = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
        else i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:" + c.getPackageName()));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            c.startActivity(i);
            call.resolve();
        } catch (Exception e) {
            call.reject("fail");
        }
    }

    /** Приложения с иконкой запуска (для выбора разрешённых). */
    @PluginMethod
    public void listApps(PluginCall call) {
        Context c = getContext();
        PackageManager pm = c.getPackageManager();
        Intent mi = new Intent(Intent.ACTION_MAIN);
        mi.addCategory(Intent.CATEGORY_LAUNCHER);
        List<String[]> l = new ArrayList<>();
        for (ResolveInfo r : pm.queryIntentActivities(mi, 0)) {
            String p = r.activityInfo.packageName;
            if (p.equals(c.getPackageName())) continue;
            l.add(new String[]{String.valueOf(r.loadLabel(pm)), p});
        }
        Collections.sort(l, (x, y) -> x[0].compareToIgnoreCase(y[0]));
        JSArray arr = new JSArray();
        String last = "";
        for (String[] x : l) {
            if (x[1].equals(last)) continue;
            last = x[1];
            JSObject o = new JSObject();
            o.put("n", x[0]);
            o.put("p", x[1]);
            arr.put(o);
        }
        JSObject res = new JSObject();
        res.put("apps", arr);
        call.resolve(res);
    }

    /** Какие приложения выходили на передний план за период [from, to] (кроме нашего). */
    @PluginMethod
    public void leftApps(PluginCall call) {
        Double f = call.getDouble("from"), t = call.getDouble("to");
        JSObject res = new JSObject();
        JSArray arr = new JSArray();
        if (f == null || t == null || !usageGranted()) {
            res.put("granted", false);
            res.put("events", arr);
            call.resolve(res);
            return;
        }
        UsageStatsManager um = (UsageStatsManager) getContext().getSystemService(Context.USAGE_STATS_SERVICE);
        UsageEvents ev = um.queryEvents(f.longValue(), t.longValue());
        UsageEvents.Event e = new UsageEvents.Event();
        String me = getContext().getPackageName();
        while (ev.hasNextEvent()) {
            ev.getNextEvent(e);
            if (e.getEventType() == UsageEvents.Event.MOVE_TO_FOREGROUND && !me.equals(e.getPackageName())) {
                JSObject o = new JSObject();
                o.put("p", e.getPackageName());
                o.put("t", e.getTimeStamp());
                arr.put(o);
            }
        }
        res.put("granted", true);
        res.put("events", arr);
        call.resolve(res);
    }
}
