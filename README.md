# Auto Internship Finder & Tailor

Aplikasi Android pencari lowongan magang yang berjalan **sepenuhnya di HP** — dashboard
sekaligus engine eksekusi. Tidak ada server atau VPS berbayar: database memakai Google
Sheets, kecerdasan memakai Gemini API, penjadwalan memakai WorkManager.

Alur harian: cari loker → buang yang sudah pernah dilihat → hitung kecocokan dengan CV
kamu pakai AI → buat cover letter yang disesuaikan → simpan ke Sheets → notifikasi.
Lamarannya semi-otomatis: aplikasi membuka link di WebView dan menyediakan tombol salin,
tapi **submit tetap kamu yang tekan** supaya aman dari anti-bot.

## Struktur

```
gas/    Backend Google Apps Script (Code.gs) + skema sheet + kontrak API
lib/
  core/       models (port dari src/types.ts), prompt builder, settings
  data/       gas_client, gemini_client, job_source, cv_reader
  pipeline/   daily_pipeline, scheduler (WorkManager), notifier
  ui/         dashboard, detail, apply (WebView), settings
assets/prompts/   template prompt Gemini
src/    Versi TypeScript asli dari core AI (referensi port, lihat catatan di bawah)
test/   104 unit/integration test
```

Dokumentasi backend ada di [`gas/README.md`](gas/README.md) — skema sheet, langkah deploy,
dan kontrak setiap `action`.

## Setup

**1. Backend** — ikuti `gas/README.md`: buat spreadsheet, tempel `gas/Code.gs`, jalankan
`setup()` lalu `generateApiToken()`, deploy sebagai Web App dengan akses *Anyone*.

**2. Aplikasi**

```
flutter pub get
flutter run
```

Buka **Settings** di aplikasi dan isi:

| Field | Dari mana |
|---|---|
| URL Web App (`/exec`) | Deploy → Manage deployments |
| API Token GAS | log `generateApiToken()` |
| Gemini API Key | [aistudio.google.com](https://aistudio.google.com) |
| JSearch atau SerpAPI Key | RapidAPI / serpapi.com |
| Teks CV | tempel manual, atau tombol *Ambil file PDF/TXT* |

Lalu atur kategori posisi, lokasi, jam pemindaian, dan aktifkan
**Pemindaian otomatis**. Tombol *Pindai Sekarang* di dashboard menjalankan alur
yang sama tanpa menunggu jadwal.

## Tes

```
flutter test                        # 104 test Dart
node gas/test/code.gs.test.cjs      # 50 assertion backend GAS
flutter analyze lib test            # harus bersih
```

`test/fixtures/prompt_golden.txt` adalah output asli dari `src/prompt.ts` (TypeScript).
Tes `prompt_test.dart` memastikan port Dart menghasilkan prompt **byte-identik**, jadi
template dan logika substitution tidak bergeser saat dipindah bahasa.

## Batasan teknis yang membentuk desain

Beberapa hal di bawah ini bukan preferensi, tapi paksaan platform. Mengubahnya tanpa
memahami alasannya akan merusak aplikasi secara diam-diam.

**GAS membalas 302, dan Dart tidak mengikutinya untuk POST.**
`dart:io` hanya menganggap redirect otomatis untuk POST berstatus **303** (lihat
`_HttpClientResponse.isRedirect` di SDK). Apps Script membalas 302, jadi `http.post()`
biasa akan menerima 302 berbody kosong tanpa JSON apa pun. `GasClient` karena itu
mengikuti redirect manual. Saat mengikuti 301/302/303 yang berasal dari POST, method
diganti jadi GET tanpa body — URL echo GAS menyajikan hasil `doPost` lewat GET, dan
mem-POST ulang ke sana dibalas halaman login (terverifikasi terhadap deployment asli).
Hanya 307/308 yang mempertahankan method dan body.

**WorkManager tidak bisa menjadwalkan "tepat pukul 12:00".**
Periodic work hanya mengenal interval (minimum 15 menit), dan `initialDelay` bersifat
"tidak lebih cepat dari", bukan waktu absolut. Solusinya: task periodik tiap jam yang
mengecek sendiri apakah sudah lewat jam target dan belum jalan hari ini. Eksekusi bisa
molor sampai ~59 menit setelah jam target, tapi dijamin tepat sekali sehari.
Logikanya ada di `decideWhetherToRun()` dan teruji.

**`INTERNET` tidak ada di manifest utama Flutter.**
Flutter hanya mendeklarasikannya di source set `debug` dan `profile`. Tanpa menambahnya
ke `android/app/src/main/AndroidManifest.xml`, build release tidak punya jaringan sama
sekali.

**`flutter_local_notifications` mewajibkan core library desugaring.**
Sejak v10 plugin ini butuh desugaring **walaupun aplikasi tidak memakai scheduled
notification** — dan kita memang tidak memakainya, notifikasi hanya ditampilkan setelah
pipeline selesai. Tanpa itu build gagal di task `checkDebugAarMetadata`. Sudah dikonfigurasi
di `android/app/build.gradle.kts`: flag `isCoreLibraryDesugaringEnabled = true` plus
dependency `com.android.tools:desugar_jdk_libs:2.1.4`. Butuh AGP minimal 8.11.1.

**Overlay salin bukan system overlay.**
Karena WebView-nya milik kita sendiri (bukan Custom Tabs), panel salin cukup berupa
widget di dalam `Stack`. Tidak perlu izin `SYSTEM_ALERT_WINDOW` yang sering ditolak OEM.

**Normalisasi URL hanya ada di satu tempat.**
Aturan anti-duplikat (buang `utm_*`, `www`, fragment, slash akhir) hidup **hanya** di
`Code.gs`. Sengaja tidak diduplikasi ke Dart: dua implementasi bisa menyimpang, dan
penyimpangan itu membuat duplikat lolos tanpa gejala apa pun.

**Kuota Gemini dijaga lewat `maxAnalyzePerRun`.**
Loker yang gagal dianalisis **tidak** disimpan ke sheet, jadi besok masih dianggap baru
dan dicoba lagi. Yang di luar batas harian juga dibiarkan tidak tersimpan.

**CV hasil scan tidak bisa dipakai.**
`CvReader` mendeteksi PDF tanpa lapisan teks dan menolaknya dengan pesan jelas, alih-alih
mengirim string kosong yang membuat Gemini memberi skor 0 tanpa penjelasan.

## Catatan soal `src/`

`src/types.ts` dan `src/prompt.ts` adalah versi TypeScript dari lapisan AI yang sudah
diporting ke `lib/core/`. Keduanya **tidak dipakai saat runtime** — Node tidak tersedia
di Android. File itu dipertahankan sementara sebagai acuan tes golden; setelah port
dianggap stabil, keduanya bisa dihapus.

`templates/career_intelligence_engine.txt` kini hidup di `assets/prompts/` (isinya
identik) karena Flutter memuatnya sebagai asset.
