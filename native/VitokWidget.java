package __APP_ID__;

import android.app.PendingIntent;
import android.appwidget.AppWidgetManager;
import android.appwidget.AppWidgetProvider;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import android.widget.RemoteViews;

public class VitokWidget extends AppWidgetProvider {
    @Override
    public void onUpdate(Context context, AppWidgetManager manager, int[] ids) {
        for (int id : ids) {
            manager.updateAppWidget(id, build(context));
        }
    }

    public static void refresh(Context context) {
        try {
            AppWidgetManager manager = AppWidgetManager.getInstance(context);
            int[] ids = manager.getAppWidgetIds(new ComponentName(context, VitokWidget.class));
            if (ids == null) return;
            for (int id : ids) {
                manager.updateAppWidget(id, build(context));
            }
        } catch (Exception e) {
        }
    }

    static RemoteViews build(Context context) {
        SharedPreferences sp = context.getSharedPreferences("vitok_widget", Context.MODE_PRIVATE);
        RemoteViews v = new RemoteViews(context.getPackageName(), R.layout.vitok_widget);
        int streak = sp.getInt("streak", 0);
        int sparks = sp.getInt("sparks", 0);
        int min = sp.getInt("min", 0);
        int done = sp.getInt("done", 0);
        int total = sp.getInt("total", 0);
        v.setTextViewText(R.id.vw_streak, "\uD83D\uDD25 " + streak);
        v.setTextViewText(R.id.vw_sparks, "\u2728 " + sparks);
        v.setTextViewText(R.id.vw_min, min + " мин сегодня");
        v.setTextViewText(R.id.vw_habits, total > 0 ? ("Привычки " + done + " из " + total) : "Открой Виток");
        Intent launch = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launch != null) {
            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
            PendingIntent pi = PendingIntent.getActivity(context, 0, launch, flags);
            v.setOnClickPendingIntent(R.id.vw_root, pi);
        }
        return v;
    }
}
