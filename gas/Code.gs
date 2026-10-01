/**
 * Auto Internship Finder & Tailor - REST API Backend
 * Google Apps Script + Google Sheets (bound script).
 *
 * Semua endpoint dipanggil lewat SATU URL Web App dengan parameter `action`.
 * Lihat README.md untuk skema sheet, cara deploy, dan kontrak tiap action.
 */

var CONFIG = {
  sheetJobs: 'Jobs_Log',
  sheetHistory: 'Applied_History',
  timezone: 'Asia/Jakarta',
  lockTimeoutMs: 30000,
  defaultLimit: 50,
  maxLimit: 200
};

// Kolom 1-7 pada Jobs_Log mengikuti spesifikasi (id..status), sisanya menampung
// hasil analisis Gemini (CareerAnalysisResult di src/types.ts).
var JOBS_COLUMNS = [
  'id', 'title', 'company', 'location', 'job_url', 'match_score', 'status',
  'match_level', 'key_matching_skills', 'missing_requirements', 'match_reason',
  'tailored_summary', 'cover_letter', 'created_at', 'updated_at'
];

var HISTORY_COLUMNS = ['applied_at', 'job_url', 'company', 'tailored_summary'];

var ALLOWED_STATUS = ['NEW', 'VIEWED', 'SAVED', 'APPLIED', 'REJECTED'];

// Kolom tanggal wajib berformat teks. Tanpa ini Sheets mengonversi string
// seperti "2026-10-01 12:00:00" menjadi nilai Date, sehingga getValues()
// mengembalikan objek Date yang string-nya tidak bisa diurutkan/dibandingkan.
var TEXT_COLUMNS = {
  Jobs_Log: ['created_at', 'updated_at'],
  Applied_History: ['applied_at']
};

// Parameter tracking/paginasi dibuang agar satu lowongan dengan link berbeda
// tetap terdeteksi sebagai duplikat.
var TRACKING_PARAMS = [
  'utm_source', 'utm_medium', 'utm_campaign', 'utm_term', 'utm_content',
  'fbclid', 'gclid', 'igshid', 'ref', 'refid', 'src', 'trk', 'trackingid',
  'position', 'start'
];

// ---------------------------------------------------------------- entrypoints

function doGet(e) {
  return handle_(e, readQueryString_(e));
}

function doPost(e) {
  return handle_(e, readPostBody_(e));
}

function handle_(e, params) {
  try {
    var action = String(params.action || 'health').toLowerCase();

    if (action !== 'health') {
      assertAuthorized_(params);
    }

    var result;
    switch (action) {
      case 'health':         result = actionHealth_(); break;
      case 'bootstrap':      result = actionBootstrap_(); break;
      case 'filter_new':     result = actionFilterNew_(params); break;
      case 'save_analysis':  result = actionSaveAnalysis_(params); break;
      case 'list_jobs':      result = actionListJobs_(params); break;
      case 'get_job':        result = actionGetJob_(params); break;
      case 'update_status':  result = actionUpdateStatus_(params); break;
      case 'mark_applied':   result = actionMarkApplied_(params); break;
      case 'list_applied':   result = actionListApplied_(params); break;
      default: throw apiError_('unknown_action', 'Action tidak dikenal: ' + action);
    }

    return json_({ ok: true, action: action, data: result });
  } catch (err) {
    return json_({
      ok: false,
      error: { code: err.code || 'internal_error', message: err.message }
    });
  }
}

// -------------------------------------------------------------------- actions

function actionHealth_() {
  var props = PropertiesService.getScriptProperties();
  return {
    service: 'auto-internship-finder-api',
    version: 1,
    time: now_(),
    spreadsheet_id: getSpreadsheet_().getId(),
    token_configured: !!props.getProperty('API_TOKEN'),
    sheets: [CONFIG.sheetJobs, CONFIG.sheetHistory]
  };
}

function actionBootstrap_() {
  var lock = acquireLock_();
  try {
    var jobs = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
    var history = ensureSheet_(CONFIG.sheetHistory, HISTORY_COLUMNS);
    return {
      jobs_log_columns: JOBS_COLUMNS,
      applied_history_columns: HISTORY_COLUMNS,
      jobs_rows: Math.max(jobs.getLastRow() - 1, 0),
      history_rows: Math.max(history.getLastRow() - 1, 0)
    };
  } finally {
    lock.releaseLock();
  }
}

/**
 * Step 3 alur harian: buang URL yang sudah pernah tercatat (status apa pun)
 * sebelum dikirim ke Gemini API.
 */
function actionFilterNew_(params) {
  var incoming = toArray_(params.jobs);
  if (!incoming.length) throw apiError_('bad_request', 'Field `jobs` (array) wajib diisi.');

  var index = buildUrlIndex_();
  var fresh = [];
  var duplicates = [];

  var seenThisBatch = {};
  incoming.forEach(function (job) {
    var url = String(job.job_url || job.url || '').trim();
    if (!url) {
      duplicates.push({ job_url: '', reason: 'missing_url' });
      return;
    }

    var key = normalizeUrl_(url);
    var existing = index[key];
    if (existing) {
      duplicates.push({
        job_url: url,
        url_key: key,
        reason: 'already_in_database',
        existing_id: existing.id,
        existing_status: existing.status
      });
      return;
    }
    if (seenThisBatch[key]) {
      duplicates.push({ job_url: url, url_key: key, reason: 'duplicate_in_batch' });
      return;
    }

    seenThisBatch[key] = true;
    fresh.push({
      title: str_(job.title),
      company: str_(job.company),
      location: str_(job.location),
      job_url: url,
      url_key: key,
      description: str_(job.description)
    });
  });

  return {
    received: incoming.length,
    new_count: fresh.length,
    duplicate_count: duplicates.length,
    new_jobs: fresh,
    duplicates: duplicates
  };
}

/**
 * Step 5 alur harian: simpan hasil analisis Gemini. Upsert berdasarkan URL,
 * jadi menjalankan ulang pipeline tidak menciptakan baris ganda.
 */
function actionSaveAnalysis_(params) {
  var incoming = toArray_(params.jobs);
  if (!incoming.length) throw apiError_('bad_request', 'Field `jobs` (array) wajib diisi.');

  var lock = acquireLock_();
  try {
    var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
    var index = buildUrlIndex_();
    var stamp = now_();

    var created = [];
    var updated = [];
    var rowsToAppend = [];

    dedupeBatch_(incoming).forEach(function (entry) {
      var item = entry.item;
      var analysis = item.analysis || item;
      var info = analysis.job_info || {};
      var match = analysis.match_analysis || {};
      var materials = analysis.application_materials || {};

      var url = entry.url;

      var record = {
        title: str_(item.title || info.title),
        company: str_(item.company || info.company),
        location: str_(item.location || info.location),
        job_url: url,
        match_score: toScore_(match.match_score),
        status: normalizeStatus_(item.status, 'NEW'),
        match_level: String(match.match_level || levelFromScore_(match.match_score) || '').toUpperCase(),
        key_matching_skills: joinList_(match.key_matching_skills),
        missing_requirements: joinList_(match.missing_requirements),
        match_reason: str_(match.match_reason),
        tailored_summary: str_(materials.tailored_summary),
        cover_letter: str_(materials.cover_letter),
        updated_at: stamp
      };

      var existing = index[entry.key];
      if (existing) {
        // Status lama dipertahankan kalau lebih "jauh" (sudah APPLIED dsb.)
        // agar re-run pipeline tidak menurunkan loker yang sudah dilamar.
        if (statusRank_(existing.status) >= statusRank_(record.status)) {
          record.status = existing.status;
        }
        writeRow_(sheet, existing.row, toRow_(existing.id, entry.key, record, existing.created_at));
        updated.push({ id: existing.id, job_url: url, status: record.status });
      } else {
        var id = newId_();
        record.created_at = stamp;
        rowsToAppend.push(toRow_(id, entry.key, record, stamp));
        created.push({ id: id, job_url: url, status: record.status, match_score: record.match_score });
      }
    });

    if (rowsToAppend.length) {
      sheet.getRange(sheet.getLastRow() + 1, 1, rowsToAppend.length, JOBS_COLUMNS.length)
        .setValues(rowsToAppend);
    }

    return {
      saved: created.length + updated.length,
      created_count: created.length,
      updated_count: updated.length,
      created: created,
      updated: updated
    };
  } finally {
    lock.releaseLock();
  }
}

/** URL yang muncul lebih dari sekali dalam satu batch disatukan (yang terakhir menang). */
function dedupeBatch_(incoming) {
  var byKey = {};
  var order = [];

  incoming.forEach(function (item) {
    var analysis = item.analysis || item;
    var info = (analysis && analysis.job_info) || {};
    var url = String(item.job_url || info.job_url || item.url || '').trim();
    if (!url) throw apiError_('bad_request', 'Setiap job wajib punya `job_url`.');

    var key = normalizeUrl_(url);
    if (!byKey[key]) {
      byKey[key] = { key: key, url: url, item: item };
      order.push(key);
    } else {
      byKey[key].item = item;
    }
  });

  return order.map(function (key) { return byKey[key]; });
}

function actionListJobs_(params) {
  var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
  var jobs = readJobs_(sheet);

  var status = params.status ? String(params.status).toUpperCase().split(',') : null;
  var minScore = params.min_score === undefined || params.min_score === ''
    ? null : Number(params.min_score);
  var search = params.search ? String(params.search).toLowerCase() : null;
  var excludeStatus = params.exclude_status
    ? String(params.exclude_status).toUpperCase().split(',') : null;

  var filtered = jobs.filter(function (job) {
    if (status && status.indexOf(job.status) === -1) return false;
    if (excludeStatus && excludeStatus.indexOf(job.status) !== -1) return false;
    if (minScore !== null && !isNaN(minScore) && job.match_score < minScore) return false;
    if (search) {
      var haystack = (job.title + ' ' + job.company + ' ' + job.location).toLowerCase();
      if (haystack.indexOf(search) === -1) return false;
    }
    return true;
  });

  filtered.sort(function (a, b) {
    if (b.match_score !== a.match_score) return b.match_score - a.match_score;
    return String(b.created_at).localeCompare(String(a.created_at));
  });

  var limit = clampLimit_(params.limit);
  var offset = Math.max(parseInt(params.offset, 10) || 0, 0);
  var page = filtered.slice(offset, offset + limit);

  return {
    total: filtered.length,
    limit: limit,
    offset: offset,
    returned: page.length,
    jobs: page.map(function (job) { return publicJob_(job, false); })
  };
}

function actionGetJob_(params) {
  var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
  var job = findJob_(sheet, params);
  return { job: publicJob_(job, true) };
}

function actionUpdateStatus_(params) {
  var status = normalizeStatus_(params.status, null);
  if (!status) throw apiError_('bad_request', 'Status wajib salah satu dari: ' + ALLOWED_STATUS.join(', '));

  var lock = acquireLock_();
  try {
    var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
    var job = findJob_(sheet, params);

    sheet.getRange(job.row, JOBS_COLUMNS.indexOf('status') + 1).setValue(status);
    sheet.getRange(job.row, JOBS_COLUMNS.indexOf('updated_at') + 1).setValue(now_());

    var result = { id: job.id, job_url: job.job_url, status: status };

    if (status === 'APPLIED') {
      result.history = appendHistory_(job, params.tailored_summary);
    }
    return result;
  } finally {
    lock.releaseLock();
  }
}

/**
 * Dipanggil aplikasi setelah pengguna submit manual di WebView. Menandai
 * Jobs_Log = APPLIED dan merekam di Applied_History supaya link diabaikan
 * pada pencarian harian berikutnya.
 */
function actionMarkApplied_(params) {
  var lock = acquireLock_();
  try {
    var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
    var job = findJob_(sheet, params);
    var stamp = now_();

    sheet.getRange(job.row, JOBS_COLUMNS.indexOf('status') + 1).setValue('APPLIED');
    sheet.getRange(job.row, JOBS_COLUMNS.indexOf('updated_at') + 1).setValue(stamp);

    var summary = params.tailored_summary !== undefined
      ? str_(params.tailored_summary)
      : job.tailored_summary;

    return {
      id: job.id,
      job_url: job.job_url,
      status: 'APPLIED',
      applied_at: stamp,
      history: appendHistory_(job, summary, stamp)
    };
  } finally {
    lock.releaseLock();
  }
}

function actionListApplied_(params) {
  var sheet = ensureSheet_(CONFIG.sheetHistory, HISTORY_COLUMNS);
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return { total: 0, applications: [] };

  var values = sheet.getRange(2, 1, lastRow - 1, HISTORY_COLUMNS.length).getValues();
  var rows = values
    .filter(function (r) { return String(r[1]).trim() !== ''; })
    .map(function (r) {
      return {
        applied_at: String(r[0]),
        job_url: String(r[1]),
        company: String(r[2]),
        tailored_summary: String(r[3])
      };
    })
    .reverse();

  var limit = clampLimit_(params.limit);
  return { total: rows.length, applications: rows.slice(0, limit) };
}

// ----------------------------------------------------------------- sheet layer

function getSpreadsheet_() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  if (ss) return ss;

  var id = PropertiesService.getScriptProperties().getProperty('SPREADSHEET_ID');
  if (!id) {
    throw apiError_('config_error',
      'Script tidak ter-bound ke Spreadsheet. Jalankan dari Extensions > Apps Script ' +
      'di dalam Google Sheets, atau isi Script Property SPREADSHEET_ID.');
  }
  return SpreadsheetApp.openById(id);
}

function ensureSheet_(name, columns) {
  var ss = getSpreadsheet_();
  var sheet = ss.getSheetByName(name);
  if (!sheet) sheet = ss.insertSheet(name);

  if (sheet.getLastRow() === 0) {
    sheet.getRange(1, 1, 1, columns.length).setValues([columns]);
    sheet.setFrozenRows(1);

    (TEXT_COLUMNS[name] || []).forEach(function (col) {
      var idx = columns.indexOf(col) + 1;
      if (idx > 0) {
        sheet.getRange(1, idx, sheet.getMaxRows(), 1).setNumberFormat('@');
      }
    });
  }
  return sheet;
}

function readJobs_(sheet) {
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) return [];

  var values = sheet.getRange(2, 1, lastRow - 1, JOBS_COLUMNS.length).getValues();
  var jobs = [];
  for (var i = 0; i < values.length; i++) {
    var row = values[i];
    if (!String(row[4]).trim() && !String(row[0]).trim()) continue;
    jobs.push(rowToJob_(row, i + 2));
  }
  return jobs;
}

function rowToJob_(row, rowNumber) {
  return {
    row: rowNumber,
    id: String(row[0]),
    title: String(row[1]),
    company: String(row[2]),
    location: String(row[3]),
    job_url: String(row[4]),
    url_key: normalizeUrl_(String(row[4])),
    match_score: toScore_(row[5]),
    status: normalizeStatus_(row[6], 'NEW'),
    match_level: String(row[7]),
    key_matching_skills: splitList_(row[8]),
    missing_requirements: splitList_(row[9]),
    match_reason: String(row[10]),
    tailored_summary: String(row[11]),
    cover_letter: String(row[12]),
    created_at: String(row[13]),
    updated_at: String(row[14])
  };
}

function buildUrlIndex_() {
  var sheet = ensureSheet_(CONFIG.sheetJobs, JOBS_COLUMNS);
  var lastRow = sheet.getLastRow();
  var index = {};
  if (lastRow < 2) return index;

  var values = sheet.getRange(2, 1, lastRow - 1, JOBS_COLUMNS.length).getValues();
  for (var i = 0; i < values.length; i++) {
    var url = String(values[i][4]).trim();
    if (!url) continue;
    var key = normalizeUrl_(url);
    // Baris paling awal yang menang supaya row number selalu merujuk ke record asli.
    if (!index[key]) {
      index[key] = {
        id: String(values[i][0]),
        row: i + 2,
        status: normalizeStatus_(values[i][6], 'NEW'),
        created_at: String(values[i][13])
      };
    }
  }
  return index;
}

function findJob_(sheet, params) {
  var id = params.id ? String(params.id).trim() : '';
  var url = params.job_url ? String(params.job_url).trim() : '';
  if (!id && !url) throw apiError_('bad_request', 'Butuh `id` atau `job_url`.');

  var jobs = readJobs_(sheet);
  var target = null;

  if (id) {
    target = jobs.filter(function (j) { return j.id === id; })[0] || null;
  }
  if (!target && url) {
    var key = normalizeUrl_(url);
    target = jobs.filter(function (j) { return j.url_key === key; })[0] || null;
  }
  if (!target) {
    throw apiError_('not_found', 'Job tidak ditemukan untuk id=' + id + ' url=' + url);
  }
  return target;
}

function writeRow_(sheet, rowNumber, values) {
  sheet.getRange(rowNumber, 1, 1, values.length).setValues([values]);
}

function toRow_(id, urlKey, record, createdAt) {
  var row = [];
  JOBS_COLUMNS.forEach(function (col) {
    switch (col) {
      case 'id': row.push(id); break;
      case 'job_url': row.push(record.job_url || urlKey); break;
      case 'created_at': row.push(record.created_at || createdAt); break;
      default:
        row.push(record[col] === undefined ? '' : record[col]);
    }
  });
  return row;
}

function appendHistory_(job, summary, stamp) {
  var sheet = ensureSheet_(CONFIG.sheetHistory, HISTORY_COLUMNS);
  var appliedAt = stamp || now_();
  var url = job.job_url;
  var company = job.company;
  var text = summary === undefined || summary === null ? job.tailored_summary : String(summary);

  var lastRow = sheet.getLastRow();
  if (lastRow >= 2) {
    var values = sheet.getRange(2, 1, lastRow - 1, HISTORY_COLUMNS.length).getValues();
    var key = normalizeUrl_(url);
    for (var i = values.length - 1; i >= 0; i--) {
      if (normalizeUrl_(String(values[i][1])) === key) {
        writeRow_(sheet, i + 2, [appliedAt, url, company, text]);
        return { applied_at: appliedAt, updated_existing_row: i + 2 };
      }
    }
  }

  sheet.appendRow([appliedAt, url, company, text]);
  return { applied_at: appliedAt, row: sheet.getLastRow() };
}

// --------------------------------------------------------------------- helpers

function json_(payload) {
  return ContentService
    .createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

function apiError_(code, message) {
  var err = new Error(message);
  err.code = code;
  return err;
}

function acquireLock_() {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(CONFIG.lockTimeoutMs);
  } catch (e) {
    throw apiError_('locked', 'Sistem sedang memproses request lain, coba lagi sebentar.');
  }
  return lock;
}

function assertAuthorized_(params) {
  var expected = PropertiesService.getScriptProperties().getProperty('API_TOKEN');
  if (!expected) {
    throw apiError_('config_error',
      'Script Property API_TOKEN belum diisi. Buka Project Settings > Script Properties.');
  }
  var provided = String(params.token || params.api_token || '');
  if (provided !== expected) throw apiError_('unauthorized', 'Token tidak valid.');
}

function readQueryString_(e) {
  return (e && e.parameter) ? e.parameter : {};
}

/**
 * Klien Android sebaiknya mengirim body JSON dengan Content-Type `text/plain`
 * supaya tidak memicu CORS preflight yang tidak dilayani GAS. Isi body tetap
 * diparse sebagai JSON; form-encoded juga diterima sebagai fallback.
 */
function readPostBody_(e) {
  var params = {};
  if (e && e.parameter) {
    for (var k in e.parameter) params[k] = e.parameter[k];
  }
  if (!e || !e.postData || !e.postData.contents) return params;

  var raw = String(e.postData.contents);
  var type = String((e.postData && e.postData.type) || '');

  try {
    var parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object' && Object.prototype.toString.call(parsed) !== '[object Array]') {
      for (var key in parsed) params[key] = parsed[key];
      return params;
    }
  } catch (ignored) { /* bukan JSON, coba form-encoded */ }

  if (type.indexOf('x-www-form-urlencoded') !== -1 || raw.indexOf('=') !== -1) {
    raw.split('&').forEach(function (pair) {
      if (!pair) return;
      var idx = pair.indexOf('=');
      var name = idx === -1 ? pair : pair.slice(0, idx);
      var value = idx === -1 ? '' : pair.slice(idx + 1);
      params[decodeURIComponent(name.replace(/\+/g, ' '))] =
        decodeURIComponent(value.replace(/\+/g, ' '));
    });
  }
  return params;
}

function normalizeUrl_(raw) {
  var input = String(raw || '').trim();
  if (!input) return '';
  if (!/^https?:\/\//i.test(input)) input = 'https://' + input;

  try {
    var url = new URL(input);
    var host = url.hostname.toLowerCase().replace(/^www\./, '');
    var path = url.pathname.replace(/\/+$/, '');

    var query = [];
    url.searchParams.forEach(function (value, key) {
      var lower = key.toLowerCase();
      if (TRACKING_PARAMS.indexOf(lower) !== -1) return;
      query.push(lower + '=' + value);
    });
    query.sort();

    var key = host + path + (query.length ? '?' + query.join('&') : '');
    return key.toLowerCase();
  } catch (e) {
    return input.toLowerCase().replace(/^https?:\/\//, '').replace(/\/+$/, '');
  }
}

function normalizeStatus_(value, fallback) {
  var s = String(value || '').trim().toUpperCase();
  if (ALLOWED_STATUS.indexOf(s) !== -1) return s;
  return fallback;
}

function statusRank_(status) {
  var order = { NEW: 0, VIEWED: 1, SAVED: 2, REJECTED: 3, APPLIED: 4 };
  return order[String(status).toUpperCase()] === undefined ? 0 : order[String(status).toUpperCase()];
}

function toScore_(value) {
  var n = Number(value);
  if (isNaN(n)) return 0;
  return Math.max(0, Math.min(100, Math.round(n)));
}

function levelFromScore_(score) {
  var n = toScore_(score);
  if (n >= 80) return 'HIGH';
  if (n >= 50) return 'MEDIUM';
  return 'LOW';
}

function toArray_(value) {
  if (!value) return [];
  if (Object.prototype.toString.call(value) === '[object Array]') return value;
  if (typeof value === 'string') {
    try {
      var parsed = JSON.parse(value);
      if (Object.prototype.toString.call(parsed) === '[object Array]') return parsed;
      return [parsed];
    } catch (e) {
      throw apiError_('bad_request', 'Field array tidak valid (gagal parse JSON).');
    }
  }
  return [value];
}

function str_(value) {
  return value === undefined || value === null ? '' : String(value).trim();
}

function joinList_(value) {
  var arr = toArray_(value);
  return arr.map(function (v) { return str_(v); }).filter(Boolean).join(' | ');
}

function splitList_(value) {
  return String(value || '')
    .split('|')
    .map(function (v) { return v.trim(); })
    .filter(Boolean);
}

function clampLimit_(value) {
  var n = parseInt(value, 10);
  if (isNaN(n) || n <= 0) return CONFIG.defaultLimit;
  return Math.min(n, CONFIG.maxLimit);
}

function publicJob_(job, includeMaterials) {
  var out = {
    id: job.id,
    title: job.title,
    company: job.company,
    location: job.location,
    job_url: job.job_url,
    match_score: job.match_score,
    match_level: job.match_level || levelFromScore_(job.match_score),
    status: job.status,
    match_reason: job.match_reason,
    key_matching_skills: job.key_matching_skills,
    missing_requirements: job.missing_requirements,
    created_at: job.created_at,
    updated_at: job.updated_at
  };
  if (includeMaterials) {
    out.tailored_summary = job.tailored_summary;
    out.cover_letter = job.cover_letter;
  }
  return out;
}

function newId_() {
  return 'JOB-' + new Date().getTime().toString(36).toUpperCase() +
    '-' + Math.floor(Math.random() * 1e6).toString(36).toUpperCase();
}

function now_() {
  return Utilities.formatDate(new Date(), CONFIG.timezone, 'yyyy-MM-dd HH:mm:ss');
}

// ---------------------------------------------------------------------- setup

/** Jalankan sekali dari editor Apps Script untuk membuat struktur sheet. */
function setup() {
  var result = actionBootstrap_();
  Logger.log(JSON.stringify(result, null, 2));
  return result;
}

/** Jalankan untuk membuat API_TOKEN acak, lalu salin ke aplikasi Flutter. */
function generateApiToken() {
  var token = Utilities.getUuid().replace(/-/g, '') + Utilities.getUuid().replace(/-/g, '');
  PropertiesService.getScriptProperties().setProperty('API_TOKEN', token);
  Logger.log('API_TOKEN: ' + token);
  return token;
}
