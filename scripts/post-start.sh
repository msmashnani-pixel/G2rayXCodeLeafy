#!/usr/bin/env bash
#!/bin/bash

# اجرای اسکریپت اصلی بدون باز کردن منوی تعاملی
# گزینه 1 انتخاب شده و سپس پاسخ‌های y برای کانفیگ داده می‌شود
export G2RAY_SOURCE_ONLY=1
source ./g2ray.sh

echo "Starting automated configuration generation..."

# این دستور دقیقاً شبیه‌سازی مراحل شماست (بدون نیاز به زدن دکمه)
# با توجه به ساختار اسکریپت شما، از توابع داخلی استفاده می‌کنیم
generate_config_auto() {
    # اگر اسکریپت شما تابع تولید کانفیگ دارد، آن را صدا می‌زنیم
    # اگر از نسخه 1.4.3 استفاده می‌کنید، معمولاً با دستور زیر انجام می‌شود:
    echo "1" | ./g2ray.sh 
    # در اینجا دستورات شما که شامل ارسال 'y' و 'Enter' هست اجرا می‌شود
    # بسته به نسخه، ممکن است نیاز باشد خروجی را به یک فایل پایپ کنید
}

# اجرای عملیات ساخت کانفیگ
# با استفاده از yes می‌توانیم پاسخ‌های 'y' را به صورت خودکار به دستور پاس دهیم
yes y | ./g2ray.sh 1

echo "Configuration generated successfully."

# حالا کانفیگ‌ها در مسیرهایی که گفتیم ایجاد شده‌اند.
# ربات شما می‌تواند آن‌ها را از ریپو بخواند.
set -u

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${G2RAY_LOG_DIR:-$BASE_DIR/logs}"
mkdir -p "$LOG_DIR" "$BASE_DIR/data" 2>/dev/null || true

ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S%z'
}

printf '%s [INFO] post_start begin\n' "$(ts)" >> "$LOG_DIR/g2ray.log" 2>/dev/null || true

if bash "$BASE_DIR/g2ray.sh" --silent-start >> "$LOG_DIR/post-start.log" 2>&1; then
    printf '%s [INFO] post_start complete\n' "$(ts)" >> "$LOG_DIR/g2ray.log" 2>/dev/null || true
    exit 0
fi

rc=$?
printf '%s [WARN] post_start failed rc=%s\n' "$(ts)" "$rc" >> "$LOG_DIR/g2ray.log" 2>/dev/null || true
exit "$rc"
