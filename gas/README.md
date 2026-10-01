# Backend GAS — Auto Internship Finder & Tailor

`Code.gs` adalah REST API untuk aplikasi Flutter. Semua request menuju **satu URL Web App**
dan dibedakan oleh parameter `action`. Database-nya Google Sheets, tanpa server bulanan.

## 1. Setup (sekali saja)

1. Buat Google Spreadsheet baru, misal `Auto Internship DB`.
2. Di spreadsheet: **Extensions → Apps Script**.
3. Hapus isi `Code.gs` bawaan, tempel seluruh isi `gas/Code.gs`, simpan.
4. Jalankan fungsi **`setup`** sekali dari editor (izinkan akses saat diminta).
   Ini membuat tab `Jobs_Log` dan `Applied_History` beserta header-nya.
5. Jalankan fungsi **`generateApiToken`**, salin token dari Execution Log.
6. **Deploy → New deployment → Web app**
   - Execute as: **Me**
   - Who has access: **Anyone**
   - Salin **Web app URL** (berakhiran `/exec`).
7. Di aplikasi Flutter simpan dua nilai itu di menu Settings:
   `GAS_URL` dan `API_TOKEN`.

> Kalau script dibuat *standalone* (bukan dari dalam spreadsheet), isi juga Script Property
> `SPREADSHEET_ID` pada **Project Settings → Script Properties**.

### Soal keamanan

Web App dengan akses "Anyone" berarti URL-nya publik. `API_TOKEN` adalah shared secret yang
menjaga agar orang lain tidak bisa menulis ke sheet kamu. Token dikirim di body/query, bukan
header — Apps Script tidak mengekspos header request ke script. Isi spreadsheet tetap privat.

Setelah mengedit `Code.gs`, buat **deployment baru** (atau *Manage deployments → Edit →
Version: New version*). URL `/exec` tidak otomatis memakai kode terbaru.

## 2. Skema Google Sheets

### Tab `Jobs_Log`

Kolom 1–7 persis mengikuti spesifikasi; kolom 8–15 menampung hasil analisis Gemini
(`CareerAnalysisResult` di `src/types.ts`).

| # | Kolom | Isi |
|---|---|---|
| 1 | `id` | `JOB-<base36 waktu>-<acak>` |
| 2 | `title` | Judul posisi |
| 3 | `company` | Perusahaan |
| 4 | `location` | Lokasi |
| 5 | `job_url` | URL asli apa adanya (tidak dinormalisasi) |
| 6 | `match_score` | 0–100 |
| 7 | `status` | `NEW` \| `VIEWED` \| `SAVED` \| `APPLIED` \| `REJECTED` |
| 8 | `match_level` | `HIGH` / `MEDIUM` / `LOW`, dihitung otomatis bila kosong |
| 9 | `key_matching_skills` | Array, disimpan sebagai teks dipisah ` \| ` |
| 10 | `missing_requirements` | Array, dipisah ` \| ` |
| 11 | `match_reason` | Penjelasan singkat |
| 12 | `tailored_summary` | Ringkasan profil untuk di-paste ke form |
| 13 | `cover_letter` | Surat lamaran hasil tailoring |
| 14 | `created_at` | `yyyy-MM-dd HH:mm:ss` (Asia/Jakarta) |
| 15 | `updated_at` | Format sama |

### Tab `Applied_History`

| # | Kolom |
|---|---|
| 1 | `applied_at` |
| 2 | `job_url` |
| 3 | `company` |
| 4 | `tailored_summary` |

> **Kolom tanggal dibuat berformat teks (`@`) otomatis oleh `bootstrap`.** Tanpa itu,
> Sheets mengonversi string seperti `2026-10-01 12:00:00` menjadi nilai Date, sehingga
> `getValues()` mengembalikan objek Date yang string-nya tidak bisa diurutkan — sorting
> dashboard dan kolom `applied_at` akan rusak tanpa gejala. Kalau kamu membuat tab
> secara manual (bukan lewat `bootstrap`), set format kolom tanggal ke *Plain text*.

## 3. Anti-duplikat

Kunci duplikat adalah **`job_url` yang dinormalisasi**, bukan string mentahnya. Sebelum
dibandingkan, URL dibuang: skema (`http`/`https`), subdomain `www`, fragment `#`, slash di
ujung path, serta parameter tracking/paginasi — `utm_*`, `fbclid`, `gclid`, `igshid`, `ref`,
`refId`, `src`, `trk`, `trackingId`, `position`, `start`. Sisa query param diurutkan.

Jadi keempat link ini dianggap **satu** lowongan:

```
https://www.linkedin.com/jobs/view/12345?utm_source=email&trk=abc&position=1
http://linkedin.com/jobs/view/12345/?fbclid=zzz&start=20
https://linkedin.com/jobs/view/12345#ref
linkedin.com/jobs/view/12345
```

Aturan spec: URL yang sudah tercatat dengan status apa pun (`APPLIED`, `SAVED`, `VIEWED`,
`NEW`) tidak akan pernah dikirim ke Gemini API maupun muncul di laporan harian lagi.

## 4. Kontrak API

### Format request

```
POST {GAS_URL}
Content-Type: text/plain        <-- PENTING, lihat catatan CORS
Body: {"action":"...", "token":"API_TOKEN", ...}
```

`Content-Type: application/json` memicu CORS preflight yang tidak dilayani Apps Script.
Kirim `text/plain` — isi body tetap diparse sebagai JSON. Body `x-www-form-urlencoded`
juga diterima. Semua request bisa juga dikirim sebagai `GET` dengan query string.

### Format response

```json
{ "ok": true,  "action": "list_jobs", "data": { ... } }
{ "ok": false, "error": { "code": "not_found", "message": "..." } }
```

Kode error: `unauthorized`, `config_error`, `bad_request`, `not_found`, `unknown_action`,
`locked`, `internal_error`.

### `health` — GET, tanpa token

Cek deployment hidup dan script ter-bound ke spreadsheet yang benar.

```
GET {GAS_URL}?action=health
```

### `bootstrap`

Membuat tab + header bila belum ada. Idempoten, aman dipanggil berulang.

### `filter_new` — Step 3 alur harian

Kirim semua hasil fetch dari JSearch/SerpAPI, terima kembali yang benar-benar baru.

```json
{
  "action": "filter_new",
  "token": "API_TOKEN",
  "jobs": [
    { "title": "Cybersecurity Intern", "company": "Telkom",
      "location": "Jakarta", "job_url": "https://...", "description": "..." }
  ]
}
```

Response `data`:

```json
{
  "received": 25, "new_count": 4, "duplicate_count": 21,
  "new_jobs": [ { "title": "...", "company": "...", "location": "...",
                  "job_url": "...", "url_key": "...", "description": "..." } ],
  "duplicates": [ { "job_url": "...", "reason": "already_in_database",
                    "existing_id": "JOB-...", "existing_status": "APPLIED" } ]
}
```

`reason`: `already_in_database` | `duplicate_in_batch` | `missing_url`.
Hanya `new_jobs` yang layak diteruskan ke Gemini API.

### `save_analysis` — Step 5 alur harian

Simpan hasil Gemini. **Upsert berdasarkan URL**, jadi re-run pipeline tidak menambah baris.

```json
{
  "action": "save_analysis",
  "token": "API_TOKEN",
  "jobs": [
    {
      "job_url": "https://linkedin.com/jobs/view/12345",
      "title": "Cybersecurity Intern",
      "company": "Telkom",
      "location": "Jakarta",
      "analysis": { "job_info": { }, "match_analysis": { }, "application_materials": { } }
    }
  ]
}
```

`analysis` adalah objek `CareerAnalysisResult` mentah dari Gemini. Objek pipih (tanpa
pembungkus `analysis`) juga diterima.

> **`job_url` wajib dikirim terpisah.** `JobInfo` di `src/types.ts` hanya berisi
> title/company/location — tidak ada URL — jadi output Gemini saja tidak cukup untuk
> menyimpan baris.

Perilaku penting: bila URL sudah ada, skor dan materi lamaran diperbarui, tapi **status
tidak pernah turun**. Loker yang sudah `APPLIED` tetap `APPLIED` walau pipeline menulis
ulang dengan status `NEW`.

Response `data`: `{ saved, created_count, updated_count, created[], updated[] }`.

### `list_jobs` — dashboard

```json
{ "action": "list_jobs", "token": "API_TOKEN",
  "status": "NEW,SAVED", "exclude_status": "APPLIED",
  "min_score": 70, "search": "cyber", "limit": 20, "offset": 0 }
```

Semua filter opsional. Hasil diurutkan `match_score` desc, lalu `created_at` desc.
`limit` default 50, maks 200. Response `data`: `{ total, limit, offset, returned, jobs[] }`.

Item `jobs[]` **tidak** menyertakan `cover_letter` dan `tailored_summary` — ambil lewat
`get_job` saat pengguna menekan tombol Tailor & Apply, supaya payload list tetap ringan.

### `get_job`

```json
{ "action": "get_job", "token": "API_TOKEN", "id": "JOB-..." }
{ "action": "get_job", "token": "API_TOKEN", "job_url": "https://..." }
```

Response `data.job` lengkap termasuk `cover_letter` dan `tailored_summary`.
Pencarian by `job_url` memakai normalisasi yang sama, jadi tracking param tidak masalah.

### `update_status`

```json
{ "action": "update_status", "token": "API_TOKEN", "id": "JOB-...", "status": "VIEWED" }
```

`status` wajib salah satu dari `NEW`, `VIEWED`, `SAVED`, `APPLIED`, `REJECTED`.
Bila diisi `APPLIED`, riwayat juga otomatis ditulis ke `Applied_History`.

### `mark_applied` — Step 5 alur apply

Dipanggil setelah pengguna submit manual di WebView.

```json
{ "action": "mark_applied", "token": "API_TOKEN", "id": "JOB-..." }
```

`tailored_summary` opsional; bila tidak dikirim, nilai yang tersimpan di sheet dipakai.
Men-set `Jobs_Log.status = APPLIED` dan upsert baris di `Applied_History` (tidak menambah
baris duplikat bila dipanggil dua kali).

### `list_applied`

```json
{ "action": "list_applied", "token": "API_TOKEN", "limit": 50 }
```

Response `data`: `{ total, applications[] }`, terbaru lebih dulu.

## 5. Pemetaan ke alur harian 12:00

| Step | Action |
|---|---|
| 2. Fetch dari JSearch/SerpAPI | — (di sisi Flutter, bukan GAS) |
| 3. Deduplication check | `filter_new` |
| 4. Gemini analysis | — (di sisi Flutter, hanya untuk `new_jobs`) |
| 5. Database update + notifikasi | `save_analysis` |
| Dashboard | `list_jobs`, `get_job` |
| Selesai submit di WebView | `mark_applied` |

## 6. Catatan skala

Apps Script gratis membatasi ±20.000 URL Fetch/hari dan eksekusi maks 6 menit. Setiap
action membaca sheet sekali per request, jadi masih nyaman sampai beberapa ribu baris.
Bila `Jobs_Log` nanti membesar, pindahkan arsip lama ke tab lain — jangan biarkan
`list_jobs` menyapu puluhan ribu baris tiap kali dashboard dibuka.

## 7. Tes lokal

```
node gas/test/code.gs.test.cjs
```

Menjalankan `Code.gs` **tanpa diubah** di dalam vm sandbox Node, dengan stub in-memory untuk
`SpreadsheetApp`, `PropertiesService`, `LockService`, `ContentService`, dan `Utilities` —
jadi logika dedup, upsert, filter, dan validasi bisa diuji tanpa deploy. 50 assertion.

Stub `LockService`-nya sengaja non-reentrant: kalau ada `acquireLock_` bersarang di dalam
action yang sudah memegang lock, tes akan gagal persis seperti deadlock di GAS sungguhan.
