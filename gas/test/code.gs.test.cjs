// Menjalankan gas/Code.gs apa adanya di dalam vm sandbox Node, dengan stub in-memory
// untuk SpreadsheetApp, PropertiesService, LockService, ContentService, dan Utilities.
// Jalankan: node gas/test/code.gs.test.cjs
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const SRC = path.join(__dirname, '..', 'Code.gs');

// ------------------------------------------------------------- in-memory sheet
function makeSheet(name, columns) {
  const grid = [];
  const formats = [];
  const sheet = {
    name,
    columns,
    _grid: grid,
    _formats: formats,
    getLastRow: () => grid.length,
    getMaxRows: () => Math.max(grid.length, 1000),
    setFrozenRows: () => {},
    appendRow: (values) => { grid.push(values.slice()); return sheet; },
    getRange: (row, col, numRows, numCols) => {
      const r = numRows || 1;
      const c = numCols || 1;
      const range = {
        getValues: () => {
          const out = [];
          for (let i = 0; i < r; i++) {
            const src = grid[row - 1 + i] || [];
            const line = [];
            for (let j = 0; j < c; j++) line.push(src[col - 1 + j] === undefined ? '' : src[col - 1 + j]);
            out.push(line);
          }
          return out;
        },
        setValues: (values) => {
          for (let i = 0; i < values.length; i++) {
            const target = row - 1 + i;
            while (grid.length <= target) grid.push([]);
            for (let j = 0; j < values[i].length; j++) {
              grid[target][col - 1 + j] = values[i][j];
            }
          }
          return range;
        },
        setValue: (value) => {
          const target = row - 1;
          while (grid.length <= target) grid.push([]);
          grid[target][col - 1] = value;
          return range;
        },
        setNumberFormat: (fmt) => {
          formats.push({ col, rows: r, fmt });
          return range;
        }
      };
      return range;
    }
  };
  return sheet;
}

function makeSpreadsheet() {
  const sheets = {};
  return {
    getId: () => 'FAKE_SPREADSHEET_ID',
    getSheetByName: (n) => sheets[n] || null,
    insertSheet: (n) => { sheets[n] = makeSheet(n); return sheets[n]; }
  };
}

// --------------------------------------------------------------------- stubs
const ss = makeSpreadsheet();
const props = { API_TOKEN: 'sekret-123' };
let lockHeld = false;

const sandbox = {
  console,
  URL,
  JSON,
  Math,
  Date,
  Number,
  String,
  Object,
  Array,
  Error,
  isNaN,
  parseInt,
  decodeURIComponent,
  SpreadsheetApp: {
    getActiveSpreadsheet: () => ss,
    openById: () => ss
  },
  PropertiesService: {
    getScriptProperties: () => ({
      getProperty: (k) => (k in props ? props[k] : null),
      setProperty: (k, v) => { props[k] = v; }
    })
  },
  // Sengaja non-reentrant: acquireLock_ bersarang akan gagal di sini, sama seperti deadlock di GAS asli.
  LockService: {
    getScriptLock: () => ({
      waitLock: () => { if (lockHeld) throw new Error('still locked'); lockHeld = true; },
      releaseLock: () => { lockHeld = false; }
    })
  },
  ContentService: {
    MimeType: { JSON: 'application/json' },
    createTextOutput: (s) => ({ _body: s, setMimeType: function () { return this; } })
  },
  Utilities: {
    formatDate: (d, tz, fmt) => '2026-10-01 12:00:00',
    getUuid: () => 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
  },
  Logger: { log: () => {} }
};
sandbox.globalThis = sandbox;

vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(SRC, 'utf8'), sandbox, { filename: 'Code.gs' });

// ------------------------------------------------------------------- helpers
let failures = 0;
let checks = 0;
function check(label, cond, extra) {
  checks++;
  if (cond) { console.log('  ok   ' + label); }
  else { failures++; console.log('  FAIL ' + label + (extra ? '\n       ' + JSON.stringify(extra) : '')); }
}
function post(body) {
  const out = sandbox.doPost({
    parameter: {},
    postData: { contents: JSON.stringify(body), type: 'text/plain' }
  });
  return JSON.parse(out._body);
}
function get(query) {
  return JSON.parse(sandbox.doGet({ parameter: query })._body);
}
const T = 'sekret-123';

// --------------------------------------------------------------------- tests
console.log('\n[1] health + auth');
const h = get({ action: 'health' });
check('health tanpa token tetap jalan', h.ok === true, h);
check('token_configured true', h.data.token_configured === true, h.data);
const denied = post({ action: 'list_jobs' });
check('tanpa token ditolak', denied.ok === false && denied.error.code === 'unauthorized', denied);
const badAction = post({ action: 'ngawur', token: T });
check('action asing ditolak', badAction.ok === false && badAction.error.code === 'unknown_action', badAction);

console.log('\n[2] bootstrap membuat header sheet');
const boot = post({ action: 'bootstrap', token: T });
check('bootstrap ok', boot.ok === true, boot);
check('Jobs_Log punya 15 kolom header',
  ss.getSheetByName('Jobs_Log')._grid[0].length === 15, ss.getSheetByName('Jobs_Log')._grid[0]);
check('Applied_History punya 4 kolom header',
  ss.getSheetByName('Applied_History')._grid[0].length === 4, ss.getSheetByName('Applied_History')._grid[0]);

console.log('\n[2b] kolom tanggal diformat teks agar tidak dikonversi Sheets');
const jobFormats = ss.getSheetByName('Jobs_Log')._formats;
const histFormats = ss.getSheetByName('Applied_History')._formats;
check('Jobs_Log created_at (kol 14) & updated_at (kol 15) -> "@"',
  JSON.stringify(jobFormats.map(f => [f.col, f.fmt])) === JSON.stringify([[14, '@'], [15, '@']]),
  jobFormats);
check('Applied_History applied_at (kol 1) -> "@"',
  JSON.stringify(histFormats.map(f => [f.col, f.fmt])) === JSON.stringify([[1, '@']]),
  histFormats);

console.log('\n[3] normalisasi URL / anti-duplikat');
const seed = post({
  action: 'save_analysis', token: T,
  jobs: [{
    job_url: 'https://www.linkedin.com/jobs/view/12345?utm_source=email&trk=abc&position=1',
    analysis: {
      job_info: { title: 'Cybersecurity Intern', company: 'Telkom', location: 'Jakarta' },
      match_analysis: {
        match_score: 88, match_level: 'HIGH',
        key_matching_skills: ['Wireshark', 'Linux'], missing_requirements: ['SIEM'],
        match_reason: 'Profil relevan.'
      },
      application_materials: { tailored_summary: 'Ringkasan.', cover_letter: 'Surat.' }
    }
  }]
});
check('save_analysis membuat 1 baris', seed.ok && seed.data.created_count === 1, seed);
const jobId = seed.data.created[0].id;
check('id terbentuk', /^JOB-/.test(jobId), jobId);

const dup = post({
  action: 'filter_new', token: T,
  jobs: [
    // URL sama, beda tracking param + tanpa www + http + trailing slash
    { job_url: 'http://linkedin.com/jobs/view/12345/?fbclid=zzz&start=20', title: 'sama' },
    { job_url: 'https://linkedin.com/jobs/view/12345?position=9&start=0', title: 'sama' },
    { job_url: 'https://glints.com/id/opportunities/99999', title: 'baru' },
    { job_url: 'https://glints.com/id/opportunities/99999', title: 'duplikat dalam batch' },
    { title: 'tanpa url' }
  ]
});
check('filter_new ok', dup.ok === true, dup);
check('hanya 1 job benar-benar baru', dup.data.new_count === 1, dup.data);
check('job baru adalah glints',
  dup.data.new_jobs[0].job_url.indexOf('glints') !== -1, dup.data.new_jobs);
check('4 dianggap duplikat', dup.data.duplicate_count === 4, dup.data.duplicates);
const reasons = dup.data.duplicates.map(d => d.reason).sort();
check('alasan duplikat benar',
  JSON.stringify(reasons) === JSON.stringify(['already_in_database', 'already_in_database', 'duplicate_in_batch', 'missing_url']),
  reasons);
check('existing_status terbawa',
  dup.data.duplicates.some(d => d.existing_status === 'NEW' && d.existing_id === jobId), dup.data.duplicates);

console.log('\n[4] job_url asli TIDAK tertimpa normalized key');
const stored = ss.getSheetByName('Jobs_Log')._grid[1];
check('job_url tetap URL lengkap',
  stored[4] === 'https://www.linkedin.com/jobs/view/12345?utm_source=email&trk=abc&position=1', stored[4]);

console.log('\n[5] upsert tidak menambah baris + status tidak turun');
post({ action: 'update_status', token: T, id: jobId, status: 'APPLIED' });
const rerun = post({
  action: 'save_analysis', token: T,
  jobs: [{
    job_url: 'https://linkedin.com/jobs/view/12345',
    analysis: {
      job_info: { title: 'Cybersecurity Intern', company: 'Telkom', location: 'Jakarta' },
      match_analysis: { match_score: 91, key_matching_skills: ['Wireshark'] },
      application_materials: { cover_letter: 'Surat v2.' }
    }
  }]
});
check('re-run menghasilkan update, bukan create',
  rerun.data.created_count === 0 && rerun.data.updated_count === 1, rerun.data);
check('total baris data tetap 1', ss.getSheetByName('Jobs_Log')._grid.length === 2, ss.getSheetByName('Jobs_Log')._grid);
const after = ss.getSheetByName('Jobs_Log')._grid[1];
check('match_score terupdate jadi 91', Number(after[5]) === 91, after[5]);
check('status APPLIED dipertahankan (tidak turun ke NEW)', after[6] === 'APPLIED', after[6]);
check('cover_letter terupdate', after[12] === 'Surat v2.', after[12]);
check('match_level dihitung otomatis dari skor', after[7] === 'HIGH', after[7]);

console.log('\n[6] Applied_History');
const hist = ss.getSheetByName('Applied_History')._grid;
check('1 riwayat tercatat', hist.length === 2, hist);
check('kolom sesuai [applied_at, job_url, company, tailored_summary]',
  hist[1][1].indexOf('linkedin.com/jobs/view/12345') !== -1 && hist[1][2] === 'Telkom', hist[1]);
const mark2 = post({ action: 'mark_applied', token: T, id: jobId });
check('mark_applied kedua tidak menambah baris duplikat',
  ss.getSheetByName('Applied_History')._grid.length === 2, ss.getSheetByName('Applied_History')._grid);
check('mark_applied balas ok', mark2.ok === true && mark2.data.status === 'APPLIED', mark2);

console.log('\n[7] list_jobs: filter + urut skor');
post({
  action: 'save_analysis', token: T,
  jobs: [
    { job_url: 'https://glints.com/id/opportunities/99999', analysis: { job_info: { title: 'IT Intern', company: 'Glints', location: 'Remote' }, match_analysis: { match_score: 60 }, application_materials: {} } },
    { job_url: 'https://jobstreet.co.id/job/555', analysis: { job_info: { title: 'Software Engineer Intern', company: 'BCA', location: 'Jakarta' }, match_analysis: { match_score: 95 }, application_materials: {} } }
  ]
});
const all = post({ action: 'list_jobs', token: T });
check('total 3 job', all.data.total === 3, all.data.total);
check('urut match_score desc',
  all.data.jobs.map(j => j.match_score).join(',') === '95,91,60', all.data.jobs.map(j => j.match_score));
check('list tidak membocorkan cover_letter', all.data.jobs[0].cover_letter === undefined, all.data.jobs[0]);

const onlyNew = post({ action: 'list_jobs', token: T, status: 'NEW' });
check('filter status NEW -> 2', onlyNew.data.total === 2, onlyNew.data.total);
const high = post({ action: 'list_jobs', token: T, min_score: 90 });
check('filter min_score 90 -> 2', high.data.total === 2, high.data.total);
const excluded = post({ action: 'list_jobs', token: T, exclude_status: 'APPLIED' });
check('exclude_status APPLIED -> 2', excluded.data.total === 2, excluded.data.total);
const searched = post({ action: 'list_jobs', token: T, search: 'bca' });
check('search case-insensitive -> 1', searched.data.total === 1, searched.data.total);
const paged = post({ action: 'list_jobs', token: T, limit: 2, offset: 1 });
check('paging limit 2 offset 1', paged.data.returned === 2 && paged.data.jobs[0].match_score === 91, paged.data);

console.log('\n[8] get_job memuat materi lamaran');
const one = post({ action: 'get_job', token: T, id: jobId });
check('get_job by id ok', one.ok && one.data.job.cover_letter === 'Surat v2.', one.data.job);
const byUrl = post({ action: 'get_job', token: T, job_url: 'http://linkedin.com/jobs/view/12345?gclid=x' });
check('get_job by url ternormalisasi', byUrl.ok && byUrl.data.job.id === jobId, byUrl);
const missing = post({ action: 'get_job', token: T, id: 'TIDAK-ADA' });
check('job tak ada -> not_found', missing.ok === false && missing.error.code === 'not_found', missing);

console.log('\n[9] validasi status & input');
const badStatus = post({ action: 'update_status', token: T, id: jobId, status: 'DITERIMA' });
check('status tak dikenal ditolak', badStatus.ok === false && badStatus.error.code === 'bad_request', badStatus);
const noKey = post({ action: 'get_job', token: T });
check('tanpa id/url ditolak', noKey.ok === false && noKey.error.code === 'bad_request', noKey);
const emptyJobs = post({ action: 'filter_new', token: T, jobs: [] });
check('jobs kosong ditolak', emptyJobs.ok === false && emptyJobs.error.code === 'bad_request', emptyJobs);
const noUrl = post({ action: 'save_analysis', token: T, jobs: [{ analysis: {} }] });
check('save tanpa job_url ditolak', noUrl.ok === false && noUrl.error.code === 'bad_request', noUrl);

console.log('\n[10] GET query-string + body form-encoded');
const viaGet = get({ action: 'list_jobs', token: T, limit: '1' });
check('GET list_jobs jalan', viaGet.ok && viaGet.data.returned === 1, viaGet);
const formBody = JSON.parse(sandbox.doPost({
  parameter: {},
  postData: { contents: 'action=list_jobs&token=sekret-123&limit=1', type: 'application/x-www-form-urlencoded' }
})._body);
check('form-encoded body diparse', formBody.ok && formBody.data.returned === 1, formBody);
const arrayBody = JSON.parse(sandbox.doPost({
  parameter: {}, postData: { contents: '[1,2,3]', type: 'text/plain' }
})._body);
check('body array tidak menyuntik index ke params (jatuh ke health)',
  arrayBody.ok === true && arrayBody.action === 'health', arrayBody);

console.log('\n[11] skills array disimpan & dibaca ulang');
const skillJob = post({ action: 'list_jobs', token: T, search: 'glints' });
check('key_matching_skills berbentuk array', Array.isArray(skillJob.data.jobs[0].key_matching_skills), skillJob.data.jobs[0]);
const detail = post({ action: 'get_job', token: T, id: jobId });
check('skills round-trip dari sheet',
  JSON.stringify(detail.data.job.key_matching_skills) === JSON.stringify(['Wireshark']),
  detail.data.job.key_matching_skills);

console.log('\n[12] list_applied');
const applied = post({ action: 'list_applied', token: T });
check('list_applied total 1', applied.ok && applied.data.total === 1, applied);

console.log('\n[13] varian URL yang didokumentasikan README');
const norm = sandbox.normalizeUrl_;
const variants = [
  'https://www.linkedin.com/jobs/view/12345?utm_source=email&trk=abc&position=1',
  'http://linkedin.com/jobs/view/12345/?fbclid=zzz&start=20',
  'https://linkedin.com/jobs/view/12345#ref',
  'linkedin.com/jobs/view/12345'
];
const keys = variants.map(norm);
check('4 varian README -> 1 key yang sama',
  keys.every(k => k === keys[0]) && keys[0] === 'linkedin.com/jobs/view/12345', keys);
check('job id berbeda tetap key berbeda',
  norm('https://linkedin.com/jobs/view/12345') !== norm('https://linkedin.com/jobs/view/99999'));
check('path berbeda tidak digabung',
  norm('https://glints.com/id/opportunities/1') !== norm('https://glints.com/id/opportunities/2'));

console.log(`\n=== ${checks - failures}/${checks} lulus ===`);
process.exit(failures ? 1 : 0);
