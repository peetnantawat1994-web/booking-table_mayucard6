/**
 * MAYUCARD 6 — automatic confirmation e-mails (Google Apps Script).
 * Install this in the Google account that should be the sender (office.inspiremarketing@gmail.com). See README.md.
 *
 * Every few minutes it asks the booking system "which shops are due a confirmation e-mail?" (every table confirmed/paid
 * and the slip amounts cover the price), sends ONE e-mail per shop from this account, and reports back so nothing is sent twice.
 * The system has a switch: off (default) / dry (lists only, sends nothing) / live. Nothing is sent unless it is 'live'.
 *
 * Settings go in Project Settings > Script properties (NOT in this file):
 *   SUPABASE_URL       https://<project>.supabase.co
 *   SUPABASE_ANON_KEY  the public (anon) key — the same one the booking page uses
 *   EMAIL_TOKEN        the secret token the admin set for the sender
 */

// ---- things you may edit -------------------------------------------------------------
var CONFIG = {
  SENDER_NAME: 'MAYUCARD 6',
  REPLY_TO: '',            // leave empty to use this account's address
  BCC: '',                 // e.g. a team mailbox that should get a copy of every e-mail (leave empty for none)
  EVENT_INFO_TEXT: '',     // optional paragraph about the event day (dates, place, load-in time...). Empty = not included.
  CONTACT_LINE: '',        // optional, e.g. 'ติดต่อทีมงานทาง LINE: @xxxx'
  ASK_FOR_LOGO: true,      // add the 'please send your logo' paragraph for shops whose logo is not in the system yet (false = never ask)
  MAX_PER_RUN: 10          // e-mails per run (the trigger runs every 10 minutes)
};

function subject_(item) { return 'ยืนยันการจองบูท MAYUCARD 6 – ร้าน ' + item.shop; }

// Plain-text body. (Pure function: no Google services used, so it can be tested anywhere.)
function buildBody_(item, cfg) {
  var tableLines = (item.lines || []).map(function (l) { return '  • โต๊ะ ' + l.table + '  ' + fmt_(l.price) + ' บาท'; }).join('\n');
  var t = [];
  t.push('เรียน คุณ' + (item.contact || 'ผู้ร่วมงาน'));
  t.push('');
  t.push('ทีมงาน MAYUCARD 6 ขอบคุณที่ร่วมงานกับเรา เราได้รับการจองและยอดชำระของร้าน ' + item.shop + ' เรียบร้อยแล้ว ขอยืนยันรายละเอียดดังนี้');
  t.push('');
  t.push(tableLines);
  t.push('');
  t.push('  ยอดรวม: ' + fmt_(item.total) + ' บาท');
  t.push('  สถานะ: ยืนยันโต๊ะแล้ว');
  if (cfg.ASK_FOR_LOGO && !item.hasLogo) {
    t.push('');
    t.push('ขอความร่วมมือส่งโลโก้ร้านเป็นไฟล์ภาพความละเอียดสูง (แนะนำอย่างน้อย 1240×1748 พิกเซล) ตอบกลับอีเมลนี้ได้เลย สำหรับใช้พิมพ์');
  }
  if (cfg.EVENT_INFO_TEXT) { t.push(''); t.push(cfg.EVENT_INFO_TEXT); }
  t.push('');
  t.push('หากมีข้อสงสัย ตอบกลับอีเมลนี้ได้เลยค่ะ' + (cfg.CONTACT_LINE ? '\n' + cfg.CONTACT_LINE : ''));
  t.push('');
  t.push('ขอแสดงความนับถือ');
  t.push('ทีมงาน MAYUCARD 6');
  return t.join('\n');
}
function fmt_(n) { return Number(n || 0).toLocaleString('en-US'); }

// ---- the runner ------------------------------------------------------------------------
function props_() { return PropertiesService.getScriptProperties(); }
function rpc_(fn, payload) {
  var p = props_();
  var res = UrlFetchApp.fetch(p.getProperty('SUPABASE_URL') + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', muteHttpExceptions: true,
    headers: { apikey: p.getProperty('SUPABASE_ANON_KEY'), Authorization: 'Bearer ' + p.getProperty('SUPABASE_ANON_KEY') },
    payload: JSON.stringify(payload)
  });
  if (res.getResponseCode() !== 200) throw new Error(fn + ' failed: HTTP ' + res.getResponseCode() + ' ' + res.getContentText().slice(0, 200));
  return JSON.parse(res.getContentText());
}
function fetchQueue_(limit) { return rpc_('email_queue_fetch', { p_token: props_().getProperty('EMAIL_TOKEN'), p_limit: limit }); }
function mark_(results) { return rpc_('email_queue_mark', { p_token: props_().getProperty('EMAIL_TOKEN'), p_results: results }); }

// Run this by the trigger (see installTrigger). Sends only when the system's mode is 'live'.
function run() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(30000)) { console.log('another run is in progress'); return; }
  try {
    var q = fetchQueue_(CONFIG.MAX_PER_RUN);
    if (q.mode === 'off') { console.log('mode is OFF: nothing to do'); return; }
    if (q.invalid && q.invalid.length) console.log('Skipped (bad e-mail address): ' + q.invalid.map(function (x) { return x.shop + ' <' + x.email + '>'; }).join('; '));
    if (q.mode === 'dry') {
      console.log('DRY RUN — would send ' + q.items.length + ' e-mail(s) in this batch (nothing is sent):');
      q.items.forEach(function (i) { console.log(' - ' + i.shop + ' <' + i.email + '> tables ' + i.tables.join(' ') + ' total ' + i.total); });
      return;
    }
    var quota = MailApp.getRemainingDailyQuota();
    var items = q.items.slice(0, Math.max(0, quota));
    if (items.length < q.items.length) console.log('Daily mail quota reached; ' + (q.items.length - items.length) + ' left for later');
    items.forEach(function (item) {
      var result = { shopKey: item.shopKey, status: 'sent' };
      try {
        var opts = { name: CONFIG.SENDER_NAME };
        if (CONFIG.REPLY_TO) opts.replyTo = CONFIG.REPLY_TO;
        if (CONFIG.BCC) opts.bcc = CONFIG.BCC;
        GmailApp.sendEmail(item.email, subject_(item), buildBody_(item, CONFIG), opts);
      } catch (e) { result = { shopKey: item.shopKey, status: 'failed', error: String(e).slice(0, 250) }; }
      mark_([result]);          // record each e-mail straight away so a crash can never cause a duplicate
      console.log(result.status + ': ' + item.shop + ' <' + item.email + '>');
    });
  } finally { lock.releaseLock(); }
}

// Send the first due shop's e-mail to YOURSELF (marked [ทดสอบ]); does not mark anything as sent.
function sendTestToMe() {
  var q = fetchQueue_(1);
  if (!q.items || !q.items.length) { console.log('No shop is due right now (mode: ' + q.mode + ')'); return; }
  var me = Session.getEffectiveUser().getEmail(), item = q.items[0];
  GmailApp.sendEmail(me, '[ทดสอบ] ' + subject_(item), 'อีเมลทดสอบ — จะส่งถึง: ' + item.email + '\n\n' + buildBody_(item, CONFIG), { name: CONFIG.SENDER_NAME });
  console.log('Test e-mail sent to ' + me + ' (for ' + item.shop + ')');
}

function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'run') ScriptApp.deleteTrigger(t); });
  ScriptApp.newTrigger('run').timeBased().everyMinutes(10).create();
  console.log('Trigger installed: run() every 10 minutes');
}
function removeTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) { if (t.getHandlerFunction() === 'run') ScriptApp.deleteTrigger(t); });
  console.log('Trigger removed');
}

// Sends the FIRST due shop's e-mail to YOURSELF exactly as a customer would receive it (no "[ทดสอบ]" label, no extra line).
// Still goes only to the account that is logged in. Nothing is sent to the customer and nothing is marked as sent.
function sendPreviewToMe() {
  var q = fetchQueue_(1);
  if (!q.items || !q.items.length) { console.log('No shop is due right now (mode: ' + q.mode + ')'); return; }
  var me = Session.getEffectiveUser().getEmail(), item = q.items[0];
  var opts = { name: CONFIG.SENDER_NAME };
  if (CONFIG.REPLY_TO) opts.replyTo = CONFIG.REPLY_TO;
  GmailApp.sendEmail(me, subject_(item), buildBody_(item, CONFIG), opts);
  console.log('Preview sent to ' + me + ' (looks exactly like the real e-mail for ' + item.shop + '; it was NOT sent to the customer)');
}
