import http from 'http';
import assert from 'assert';
import fs from 'fs';

async function send_request(host, method, data = {}, session_cookie = '') {
  let path = '/index.html?lang=en';
  const origin = 'http://' + host;
  const target = origin + path;
  const headers = {
    'Content-Type': 'application/x-www-form-urlencoded',
    Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    // Do not advertise compression: this client does not decode the body, so
    // a gzip/br response would make the form-parsing regexes see garbage.
    'Accept-Encoding': 'identity',
    'Accept-Language': 'de,en-US;q=0.7,en;q=0.3',
    'Sec-Fetch-Dest': 'document',
    'Sec-Fetch-Mode': 'navigate',
    'Sec-Fetch-Site': 'same-origin',
    'Sec-Fetch-User': '?1',
    Priority: 'u=0, i',
    'Upgrade-Insecure-Requests': 1,
    'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:134.0) Gecko/20100101 Firefox/134.0',
    Referer: target,
    Origin: origin,
  };
  if (session_cookie !== '') {
    headers['Cookie'] = session_cookie;
  }
  let body = '';
  for (const key of Object.keys(data)) {
    if (body.length > 0) {
      body += '&';
    }
    if (data[key].startsWith('+%2B+')) {
      data[key] = encodeURIComponent(data[key].replace('+%2B+', '')).replace(
        /%20/g,
        '+'
      );
    } else {
      data[key] = encodeURIComponent(data[key]);
    }
    body += key + '=' + data[key];
  }
  if (method === 'POST') {
    headers['Content-Length'] = body.length;
  }
  if (method === 'GET' && Object.keys(data).length > 0) {
    path += '&' + body;
  }
  const agent = new http.Agent({keepAlive: false});
  const options = {
    method,
    headers,
    agent,
  };
  console.log('Request:', method, target);
  if (method === 'POST') {
    // Never log headers (Cookie) or the raw body: they carry the admin and
    // game passwords and would leak into the Pelican console / docker logs.
    const fieldNames = Object.keys(data).join(',');
    console.log('Body fields:', fieldNames);
  }
  return new Promise((resolve, reject) => {
    const req = http.request(target, options, (res) => {
      assert(typeof res.statusCode === 'number');
      console.log('Response:', res.statusCode);
      assert(res.statusCode >= 200 && res.statusCode < 400);
      res['text'] = async () => {
        return new Promise((resolve_text) => {
          let data = '';
          res.on('data', (chunk) => {
            data += chunk;
          });
          res.on('end', () => {
            resolve_text(data);
          });
        });
      };
      resolve(res);
    });
    req.on('error', (err) => {
      reject(err);
    });
    if (method === 'POST') {
      req.write(body);
    }
    req.end();
  });
}

async function login(host, username, password) {
  const res = await send_request(host, 'GET');
  const cookies = res.headers['set-cookie'] || [];
  let session_cookie_result = null;

  for (const cookie of cookies) {
    session_cookie_result = /(SessionID=[^;]+)/i.exec(cookie);
    if (session_cookie_result !== null) break;
  }

  const request = {
    username: username,
    password: password,
    login: 'Login',
  };
  // The dedicated server only emits a SessionID cookie on the login POST
  // response, not on the initial GET — fall back to that response.
  const login_res = await send_request(
    host,
    'POST',
    request,
    session_cookie_result !== null ? session_cookie_result[1] : ''
  );
  const login_cookies = login_res.headers['set-cookie'] || [];
  for (const cookie of login_cookies) {
    const m = /(SessionID=[^;]+)/i.exec(cookie);
    if (m !== null) return m[1];
  }
  assert(session_cookie_result !== null, 'No SessionID cookie from server');
  return session_cookie_result[1];
}

// The dedi start form must be re-posted in full: map_start and the career
// fields (initialMoney, initialLoan, economicDifficulty...) are required on a
// fresh savegame, and omitting them makes the dedi silently ignore Start.
function parse_form_fields(form_html) {
  const params = {};
  for (const m of form_html.matchAll(
    /<select[^>]*name\s*=\s*"?([^"\s>]+)"?[^>]*>([\s\S]*?)<\/select>/gi
  )) {
    const sel =
      m[2].match(/<option value="([^"]*)"[^>]*selected/i) ||
      m[2].match(/<option value="([^"]*)"/i);
    if (sel) params[m[1]] = sel[1];
  }
  for (const m of form_html.matchAll(/<input([^>]*?)>/gi)) {
    const attrs = m[1];
    const type = (attrs.match(/type="([^"]*)"/i) || [])[1] || 'text';
    const name = (attrs.match(/name\s*=\s*"?([^"\s>]+)"?/i) || [])[1];
    const value = (attrs.match(/value="([^"]*)"/i) || [])[1] || '';
    if (!name || type === 'submit') continue;
    if (type === 'checkbox') {
      if (/checked/i.test(attrs)) params[name] = value || 'on';
      continue;
    }
    params[name] = value;
  }
  return params;
}

// Mods installed through the panel Mod Store only land in the dedi's mod
// pool — the save still has to be told to load them. The store records the
// zip filenames in .mod-store.json (meta.pending_activation / pending_deactivation);
// every start consumes both lists through the same modactivate_*/moddeactivate_*
// checkboxes the web UI shows while the mission is stopped, then writes back
// whatever the dedi refused so a mod queued with missing dependencies still
// activates on its own once the dependencies land.
const MODSTORE_STATE = '/home/container/.mod-store.json';

function write_modstore_state(state) {
  try {
    fs.writeFileSync(MODSTORE_STATE, JSON.stringify(state));
  } catch (e) {
    console.error('Could not write .mod-store.json:', e.message);
  }
}

function checkbox_names(html, prefix) {
  const names = new Set();
  for (const m of html.matchAll(
    new RegExp('<input[^>]*name\\s*=\\s*"?(' + prefix + '[^"\\s>]+)"?[^>]*>', 'gi')
  )) {
    names.add(m[1]);
  }
  return names;
}

async function apply_pending_mod_changes(host, session_cookie, page_html) {
  let state;
  try {
    state = JSON.parse(fs.readFileSync(MODSTORE_STATE, 'utf8'));
  } catch {
    return page_html;
  }
  const meta = state.meta || {};
  const activate = (meta.pending_activation || []).map(String);
  const deactivate = (meta.pending_deactivation || []).map(String);
  if (activate.length === 0 && deactivate.length === 0) return page_html;

  const act_boxes = checkbox_names(page_html, 'modactivate_');
  const deact_boxes = checkbox_names(page_html, 'moddeactivate_');

  const base = () => {
    const fm = page_html.match(
      /<form[^>]*name\s*=\s*"configuration"[\s\S]*?<\/form>/i
    );
    return fm ? parse_form_fields(fm[0]) : {};
  };

  const submit = async (names, button) => {
    const params = base();
    for (const n of names) params[n] = 'on';
    params[button] = '1';
    console.log(`Submitting ${button} for:`, names.join(', '));
    await send_request(host, 'POST', params, session_cookie);
  };

  const to_deactivate = deactivate
    .map((f) => 'moddeactivate_' + f)
    .filter((n) => deact_boxes.has(n));
  const to_activate = activate
    .map((f) => 'modactivate_' + f)
    .filter((n) => act_boxes.has(n));

  if (to_deactivate.length === 0 && to_activate.length === 0) {
    // Stale entries only (file gone or already in the wanted state).
    meta.pending_activation = [];
    meta.pending_deactivation = [];
    write_modstore_state(state);
    return page_html;
  }

  await submit(to_deactivate, 'deactivate_mods');
  await submit(to_activate, 'activate_mods');

  // Re-fetch: whatever the dedi refused keeps an unchecked box and stays queued.
  const res = await send_request(host, 'GET', {}, session_cookie);
  const html = await res.text();
  const left_act = checkbox_names(html, 'modactivate_');
  const left_deact = checkbox_names(html, 'moddeactivate_');
  meta.pending_activation = activate.filter((f) => left_act.has('modactivate_' + f));
  meta.pending_deactivation = deactivate.filter((f) => left_deact.has('moddeactivate_' + f));
  if (meta.pending_activation.length > 0) {
    console.log(
      'Mods still pending activation (dedi refused — missing dependencies?):',
      meta.pending_activation.join(', ')
    );
  }
  write_modstore_state(state);
  return html;
}

let main_interval = null;

async function main() {
  const host = process.env.WEBSERVER_LISTENING_ON + ':7999';

  console.log('Starting game');
  console.log('Host:', host);

  const session_cookie = await login(
    host,
    process.env.WEB_USERNAME,
    process.env.WEB_PASSWORD
  );

  console.log('Logged in');

  const res = await send_request(host, 'GET', {}, session_cookie);

  const html = await apply_pending_mod_changes(host, session_cookie, await res.text());

  const form_match = html.match(
    /<form[^>]*name\s*=\s*"configuration"[\s\S]*?<\/form>/i
  );
  assert(form_match !== null, 'configuration form not found');
  const params = parse_form_fields(form_match[0]);
  for (const key of ['game_name', 'admin_password', 'game_password']) {
    assert(typeof params[key] !== 'undefined', 'Missing key: ' + key);
  }
  params['game_name'] = '+%2B+' + params['game_name'];
  params['start_server'] = 'Start';

  console.log('Starting server');
  // Log the submitted fields with secrets masked — never print
  // admin_password/game_password values to the console.
  console.log(JSON.stringify(
    Object.fromEntries(
      Object.entries(params).map(([k, v]) => [
        k,
        /password/i.test(k) ? '•••' : v,
      ])
    ),
    null,
    2
  ));

  await send_request(host, 'POST', params, session_cookie);

  console.log('Server started');
  clearInterval(main_interval);
}

main_interval = setInterval(() => main().catch(console.error), 30000);
main().catch(console.error);
