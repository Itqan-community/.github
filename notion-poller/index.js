// notion-poller/index.js
// Long-running Railway service. Polls Notion Tasks Board every 5 min.
// Syncs Notion → GitHub: status (Done→close/else→reopen), assignees, comments.

const NOTION_KEY    = process.env.NOTION_API_KEY;
const NOTION_DB_ID  = process.env.NOTION_TASKS_DB_ID;
const GH_TOKEN      = process.env.GH_PAT_POLLER;
const USER_MAP      = JSON.parse(process.env.STANDUP_USER_MAP || '{}');
const SLACK_WEBHOOK = process.env.SLACK_WEBHOOK_ENGINEERING_ALERTS || '';
const POLL_MS       = parseInt(process.env.POLL_INTERVAL_MS || '300000');
const HWM_RAW       = process.env.STARTUP_HIGH_WATER_MARK;
const HIGH_WATER_MARK = HWM_RAW ? new Date(HWM_RAW) : new Date();

// Reverse map: notion display name → github login (exact match only — write operation)
const NOTION_TO_GH = Object.fromEntries(
  Object.entries(USER_MAP)
    .filter(([, v]) => v.notion)
    .map(([login, v]) => [v.notion, login])
);

let consecutiveFailures = 0;

// ── Notion ──────────────────────────────────────────────────────────────────

const notionHeaders = {
  Authorization: `Bearer ${NOTION_KEY}`,
  'Notion-Version': '2022-06-28',
  'Content-Type': 'application/json',
};

async function getAllTasksWithGitHubUrl() {
  const tasks = [];
  let cursor;
  while (true) {
    const body = {
      filter: { property: 'GitHub URL', url: { is_not_empty: true } },
      page_size: 100,
    };
    if (cursor) body.start_cursor = cursor;
    const res = await fetch(`https://api.notion.com/v1/databases/${NOTION_DB_ID}/query`, {
      method: 'POST',
      headers: notionHeaders,
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (!data.results) throw new Error(`Notion DB query failed: ${JSON.stringify(data)}`);
    for (const page of data.results) {
      const props = page.properties;
      const githubUrl = props['GitHub URL']?.url;
      if (!githubUrl) continue;
      // Handle both select type and native status type
      const status = props['Status']?.select?.name ?? props['Status']?.status?.name ?? '';
      const assignees = (props['Assigned To']?.people || []).map(p => p.name);
      tasks.push({ pageId: page.id, githubUrl, status, assignees });
    }
    if (!data.has_more) break;
    cursor = data.next_cursor;
  }
  return tasks;
}

async function getNotionComments(pageId) {
  const res = await fetch(`https://api.notion.com/v1/comments?block_id=${pageId}`, {
    headers: notionHeaders,
  });
  const data = await res.json();
  return data.results || [];
}

// ── GitHub ──────────────────────────────────────────────────────────────────

const ghHeaders = {
  Authorization: `Bearer ${GH_TOKEN}`,
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
};

function parseGitHubIssueUrl(url) {
  const m = url.match(/github\.com\/([^/]+)\/([^/]+)\/issues\/(\d+)/);
  if (!m) return null;
  return { owner: m[1], repo: m[2], number: parseInt(m[3]) };
}

async function ghFetch(path, opts = {}) {
  const res = await fetch(`https://api.github.com${path}`, {
    ...opts,
    headers: { ...ghHeaders, ...(opts.headers || {}) },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`GitHub ${opts.method || 'GET'} ${path} → ${res.status}: ${body}`);
  }
  return res.json();
}

// ── Sync ────────────────────────────────────────────────────────────────────

function extractNotionCommentId(body) {
  const m = (body || '').match(/<!-- notion-comment:([a-z0-9-]+) -->/);
  return m ? m[1] : null;
}

function formatComment(nc) {
  const author = nc.created_by?.name || 'Notion';
  const text = (nc.rich_text || []).map(t => t.plain_text).join('');
  return `> 💬 **${author}** (via Notion)
>
> ${text}

<!-- notion-comment:${nc.id} -->`;
}

async function syncTask({ pageId, githubUrl, status, assignees: notionAssignees }) {
  const ref = parseGitHubIssueUrl(githubUrl);
  if (!ref) return; // PR URL or non-issue URL — skip

  const { owner, repo, number } = ref;
  const issue = await ghFetch(`/repos/${owner}/${repo}/issues/${number}`);

  // ── Status sync ──
  const isDone = status === 'Done';
  if (isDone && issue.state === 'open') {
    await ghFetch(`/repos/${owner}/${repo}/issues/${number}`, {
      method: 'PATCH',
      body: JSON.stringify({ state: 'closed' }),
    });
    log(`Closed ${owner}/${repo}#${number} (Notion: Done)`);
  } else if (!isDone && status !== '' && issue.state === 'closed') {
    await ghFetch(`/repos/${owner}/${repo}/issues/${number}`, {
      method: 'PATCH',
      body: JSON.stringify({ state: 'open' }),
    });
    log(`Reopened ${owner}/${repo}#${number} (Notion: ${status})`);
  }

  // ── Assignee sync ──
  const ghLogins = notionAssignees.map(name => {
    const login = NOTION_TO_GH[name];
    if (!login) log(`No GitHub login for Notion assignee "${name}" — skipping`);
    return login;
  }).filter(Boolean);

  const currentLogins = (issue.assignees || []).map(a => a.login).sort().join(',');
  if (ghLogins.slice().sort().join(',') !== currentLogins) {
    await ghFetch(`/repos/${owner}/${repo}/issues/${number}`, {
      method: 'PATCH',
      body: JSON.stringify({ assignees: ghLogins }),
    });
    log(`Assignees ${owner}/${repo}#${number}: [${ghLogins.join(', ') || 'none'}]`);
  }

  // ── Comment sync ──
  const notionComments = await getNotionComments(pageId);
  const newComments = notionComments.filter(nc => new Date(nc.created_time) > HIGH_WATER_MARK);
  if (newComments.length === 0) return;

  const ghComments = await ghFetch(`/repos/${owner}/${repo}/issues/${number}/comments?per_page=100`);
  const postedIds = new Set(ghComments.map(c => extractNotionCommentId(c.body)).filter(Boolean));

  for (const nc of newComments) {
    if (postedIds.has(nc.id)) continue;
    await ghFetch(`/repos/${owner}/${repo}/issues/${number}/comments`, {
      method: 'POST',
      body: JSON.stringify({ body: formatComment(nc) }),
    });
    log(`Comment ${nc.id} → ${owner}/${repo}#${number}`);
  }
}

// ── Main loop ───────────────────────────────────────────────────────────────

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

async function postSlackAlert(text) {
  if (!SLACK_WEBHOOK) return;
  await fetch(SLACK_WEBHOOK, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ text: `🚨 *notion-poller:* ${text}` }),
  }).catch(e => log(`Slack alert failed: ${e.message}`));
}

async function poll() {
  log('Poll start');
  try {
    const tasks = await getAllTasksWithGitHubUrl();
    log(`${tasks.length} tasks with GitHub URL`);
    let errors = 0;
    for (const task of tasks) {
      try {
        await syncTask(task);
      } catch (err) {
        errors++;
        log(`Sync error [${task.githubUrl}]: ${err.message}`);
      }
    }
    consecutiveFailures = 0;
    log(`Poll done. Task errors: ${errors}/${tasks.length}`);
  } catch (err) {
    consecutiveFailures++;
    log(`Poll cycle failed (${consecutiveFailures} consecutive): ${err.message}`);
    if (consecutiveFailures >= 3) {
      await postSlackAlert(`${consecutiveFailures} consecutive poll failures. Last: ${err.message}`);
    }
  }
}

log(`Starting. Poll: ${POLL_MS}ms. High water mark: ${HIGH_WATER_MARK.toISOString()}`);
poll();
setInterval(poll, POLL_MS);
