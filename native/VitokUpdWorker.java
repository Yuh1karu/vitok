package __APP_ID__;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageInfo;
import android.os.Build;

import androidx.annotation.NonNull;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;
import androidx.work.Worker;
import androidx.work.WorkerParameters;

import org.json.JSONObject;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.util.Scanner;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Раз в ~30 минут смотрит последний релиз на GitHub и присылает уведомление, когда вышла новая сборка. */
public class VitokUpdWorker extends Worker {
    static final String PREFS = "vitok_upd";
    static final String CH = "vitok_update";

    public VitokUpdWorker(@NonNull Context c, @NonNull WorkerParameters p) {
        super(c, p);
    }

    @NonNull
    @Override
    public Result doWork() {
        Context ctx = getApplicationContext();
        HttpURLConnection c = null;
        try {
            SharedPreferences sp = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
            String repo = sp.getString("repo", "");
            if (repo.isEmpty()) return Result.success();

            c = (HttpURLConnection) new URL("https://api.github.com/repos/" + repo + "/releases/latest").openConnection();
            c.setConnectTimeout(15000);
            c.setReadTimeout(20000);
            c.setRequestProperty("Accept", "application/vnd.github+json");
            c.setRequestProperty("User-Agent", "Vitok-Updater");
            if (c.getResponseCode() != 200) return Result.retry();

            String body;
            try (InputStream in = c.getInputStream(); Scanner s = new Scanner(in, "UTF-8").useDelimiter("\\A")) {
                body = s.hasNext() ? s.next() : "";
            }
            JSONObject j = new JSONObject(body);
            Matcher m = Pattern.compile("build-(\\d+)").matcher(j.optString("tag_name", ""));
            if (!m.find()) return Result.success();
            long latest = Long.parseLong(m.group(1));

            PackageInfo pi = ctx.getPackageManager().getPackageInfo(ctx.getPackageName(), 0);
            long cur = Build.VERSION.SDK_INT >= 28 ? pi.getLongVersionCode() : pi.versionCode;
            if (latest <= cur) return Result.success();
            if (sp.getLong("notified", 0) >= latest) return Result.success();
            if (!NotificationManagerCompat.from(ctx).areNotificationsEnabled()) return Result.success();

            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CH) == null) {
                NotificationChannel ch = new NotificationChannel(CH, "Обновления", NotificationManager.IMPORTANCE_DEFAULT);
                ch.setDescription("Когда выходит новая версия Витка");
                nm.createNotificationChannel(ch);
            }
            Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            if (open != null) open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
            int fl = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 23 ? PendingIntent.FLAG_IMMUTABLE : 0);
            PendingIntent pi2 = PendingIntent.getActivity(ctx, 7777, open, fl);

            String name = j.optString("name", j.optString("tag_name", ""));
            NotificationCompat.Builder b = new NotificationCompat.Builder(ctx, CH)
                .setSmallIcon(ctx.getResources().getIdentifier("ic_stat_icon_config_sample", "drawable", ctx.getPackageName()))
                .setContentTitle("Вышло обновление Витка")
                .setContentText(name.isEmpty() ? "Открой приложение, чтобы обновиться" : name + ": открой приложение, чтобы обновиться")
                .setContentIntent(pi2)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT);
            nm.notify(7002, b.build());
            sp.edit().putLong("notified", latest).apply();
            return Result.success();
        } catch (Exception e) {
            return Result.retry();
        } finally {
            if (c != null) c.disconnect();
        }
    }
}
