/**
 * Azure Portal screenshot validation for Forensic Storage Lab.
 *
 * Captures screenshots of key infrastructure settings as visual evidence.
 * CLI validation (validate-demo.ps1) is the authoritative PASS/FAIL source;
 * these screenshots provide human-friendly documentation.
 *
 * Pre-step: run the profile copy script (or npm test does it automatically).
 * Uses a pre-copied Edge Profile 4 from %TEMP%\pw-edge-profile-copy.
 * No CDP, no browser restart, no install needed.
 *
 * Usage:
 *   npm test
 */
import { test, chromium, BrowserContext } from '@playwright/test';
import { execSync } from 'child_process';
import path from 'path';
import fs from 'fs';
import os from 'os';

// ── Configuration ──────────────────────────────────────────
// Resource names are taken from environment variables. Set these before running:
//   AZURE_SUBSCRIPTION_ID, AZURE_RESOURCE_GROUP, STORAGE_ACCOUNT_HNS,
//   LOG_ANALYTICS_WORKSPACE, FUNCTION_APP, EDGE_PROFILE
const SUBSCRIPTION_ID = requireEnv('AZURE_SUBSCRIPTION_ID');
const RESOURCE_GROUP = requireEnv('AZURE_RESOURCE_GROUP');
const STORAGE_ACCOUNT_HNS = requireEnv('STORAGE_ACCOUNT_HNS');
const LOG_ANALYTICS_WORKSPACE = requireEnv('LOG_ANALYTICS_WORKSPACE');
const FUNCTION_APP = requireEnv('FUNCTION_APP');
const EDGE_PROFILE = process.env.EDGE_PROFILE || 'Default';

function requireEnv(name: string): string {
  const v = process.env[name];
  if (!v) {
    throw new Error(`Environment variable ${name} is required. Set it before running this test.`);
  }
  return v;
}

const TEMP_PROFILE = path.join(os.tmpdir(), 'pw-edge-profile-copy');

const portalBase = `https://portal.azure.com/#@/resource`;
const storageBase = (acct: string) =>
  `${portalBase}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${acct}`;

const outputDir = path.join(__dirname, '..', '..', 'validation-output');

// ── Persistent context from pre-copied Edge profile ────────
let context: BrowserContext;

// ── PII patterns built dynamically from Azure CLI context ──
interface PiiPattern { re: RegExp; rep: string }
let piiPatterns: PiiPattern[] = [];
let piiMatchStrings: string[] = [];
let accountEmail = '';

function resolveAzureIdentity(): { email: string; subscriptionName: string; tenantDisplayName: string } {
  try {
    const raw = execSync('az account show --query "{email:user.name, subName:name, tenantId:tenantId}" -o json 2>nul', {
      encoding: 'utf-8', timeout: 15_000,
    });
    const acct = JSON.parse(raw);
    return {
      email: acct.email || '',
      subscriptionName: acct.subName || '',
      tenantDisplayName: '',
    };
  } catch {
    return { email: '', subscriptionName: '', tenantDisplayName: '' };
  }
}

function buildPiiPatterns(identity: ReturnType<typeof resolveAzureIdentity>): void {
  const { email, subscriptionName } = identity;
  piiPatterns = [];
  piiMatchStrings = [];

  if (subscriptionName) {
    piiPatterns.push({ re: new RegExp(subscriptionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g'), rep: '[redacted]' });
    // Build short match tokens from the subscription name
    subscriptionName.split(/[-_]/).filter(t => t.length > 3).forEach(t => piiMatchStrings.push(t));
  }
  if (email) {
    piiPatterns.push({ re: new RegExp(email.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), rep: '[redacted]' });
    const userPart = email.split('@')[0];
    if (userPart.length > 3) piiMatchStrings.push(userPart);
    const domain = email.split('@')[1];
    if (domain) {
      const domainPrefix = domain.split('.')[0];
      if (domainPrefix.length > 4) piiMatchStrings.push(domainPrefix);
    }
  }
  if (SUBSCRIPTION_ID) {
    piiPatterns.push({ re: new RegExp(SUBSCRIPTION_ID, 'g'), rep: '[redacted-id]' });
    // Match on first and last segments of the GUID
    const guidParts = SUBSCRIPTION_ID.split('-');
    if (guidParts.length >= 5) {
      piiMatchStrings.push(guidParts[0]);
      piiMatchStrings.push(guidParts[guidParts.length - 1]);
    }
  }
  // Deduplicate match strings
  piiMatchStrings = [...new Set(piiMatchStrings.filter(s => s.length > 3))];
}

// ── Profile Integrity Check ─────────────────────────────────
function verifyProfileIntegrity(profileDir: string): { valid: boolean; missing: string[] } {
  const requiredPaths = [
    { rel: path.join('Network', 'Cookies'),          desc: 'Auth session cookies' },
    { rel: path.join('Local Storage', 'leveldb'),     desc: 'Portal UI state' },
    { rel: 'Preferences',                             desc: 'Browser preferences' },
  ];
  const missing: string[] = [];
  for (const req of requiredPaths) {
    const full = path.join(profileDir, req.rel);
    if (!fs.existsSync(full)) {
      missing.push(`${req.rel} — ${req.desc}`);
    } else if (fs.statSync(full).isFile() && fs.statSync(full).size === 0) {
      missing.push(`${req.rel} — ${req.desc} (exists but empty)`);
    }
  }
  return { valid: missing.length === 0, missing };
}

test.beforeAll(async () => {
  if (!fs.existsSync(TEMP_PROFILE)) {
    throw new Error(
      `Profile copy not found at ${TEMP_PROFILE}. ` +
      'Run the copy-profile step first (npm test handles this).'
    );
  }

  // Fail fast if the profile is a "ghost" from locked-file skips
  const integrity = verifyProfileIntegrity(TEMP_PROFILE);
  if (!integrity.valid) {
    throw new Error(
      'PROFILE INTEGRITY CHECK FAILED\n\n' +
      'Essential session files were not copied, likely because Microsoft Edge\n' +
      'is currently open and has locked these files:\n\n' +
      integrity.missing.map(m => `  ✗ ${m}`).join('\n') + '\n\n' +
      'Fix: Close Microsoft Edge completely, then re-run: npm test\n' +
      'Alt: Use a different Edge profile that is not currently active.'
    );
  }

  // Resolve identity and build redaction patterns before launching browser
  const identity = resolveAzureIdentity();
  accountEmail = identity.email;
  buildPiiPatterns(identity);

  context = await chromium.launchPersistentContext(TEMP_PROFILE, {
    channel: 'msedge',
    headless: false,
    viewport: { width: 1920, height: 1080 },
    args: [
      '--disable-blink-features=AutomationControlled',
      '--no-first-run',
      '--no-default-browser-check',
      '--start-maximized',
    ],
  });
});

test.afterAll(async () => {
  if (context) await context.close();
});

// ── Diagnostic capture on failure ──────────────────────────
const diagnosticsDir = path.join(outputDir, '_diagnostics');

test.afterEach(async ({}, testInfo) => {
  if (testInfo.status !== 'passed' && testInfo.status !== 'skipped') {
    const pages = context?.pages() ?? [];
    const page = pages[pages.length - 1];
    if (page && !page.isClosed()) {
      fs.mkdirSync(diagnosticsDir, { recursive: true });
      const safeName = testInfo.title.replace(/[^a-zA-Z0-9-]/g, '_').slice(0, 60);
      const ts = new Date().toISOString().replace(/[:.]/g, '-');
      const diagPath = path.join(diagnosticsDir, `FAILED-${safeName}-${ts}.png`);
      await page.screenshot({ path: diagPath, fullPage: false }).catch(() => {});
    }
  }
});

// ── Helpers ────────────────────────────────────────────────

async function handleAccountPicker(page: import('@playwright/test').Page): Promise<void> {
  const picker = page.locator('text=Pick an account').first();
  if (await picker.isVisible({ timeout: 3000 }).catch(() => false)) {
    const target = accountEmail
      ? page.locator(`text=${accountEmail}`).first()
      : page.locator('[data-test-id="accountList"] > div').first();
    if (await target.isVisible({ timeout: 2000 }).catch(() => false)) {
      await target.click();
      await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
      await waitForPortalReady(page);
    }
  }
}

async function waitForPortalReady(page: import('@playwright/test').Page, timeout = 30_000): Promise<void> {
  try {
    await page.waitForFunction(() =>
      !!document.querySelector('#searchBoxInput') ||
      !!document.querySelector('[class*="fxs-breadcrumb"]') ||
      !!document.querySelector('[class*="azc-grid"]')
    , { timeout });
  } catch {
    console.warn(
      `⚠ waitForPortalReady timed out after ${timeout / 1000}s on ${page.url()}\n` +
      '  Screenshot may show a blank page, spinner, or login screen.'
    );
  }
}

async function redactPII(page: import('@playwright/test').Page): Promise<void> {
  // CSS to hide user identity controls in the header
  await page.addStyleTag({ content: `
    #meControl, [data-testid="mectrl_main_trigger"], .fxs-avatarmenu,
    [class*="mectrl"], [id*="mectrl"] { visibility: hidden !important; }
  `});

  // Serialize dynamic patterns for use inside page.evaluate()
  const serializedPatterns = piiPatterns.map(p => ({
    source: p.re.source, flags: p.re.flags, rep: p.rep,
  }));
  const matchStrings = piiMatchStrings;

  // Walk all frames and replace PII in text nodes
  for (const frame of page.frames()) {
    try {
      await frame.evaluate(({ patterns, matchers }) => {
        const regexes = patterns.map(p => ({ re: new RegExp(p.source, p.flags), rep: p.rep }));
        const hasPII = (t: string) => matchers.some(m => t.includes(m));
        const applyRedaction = (t: string) => {
          for (const p of regexes) t = t.replace(p.re, p.rep);
          return t;
        };

        // Pass 1: leaf elements
        document.querySelectorAll('*').forEach(el => {
          if (el.children.length === 0 && el.textContent && hasPII(el.textContent)) {
            (el as HTMLElement).textContent = applyRedaction(el.textContent);
            (el as HTMLElement).style.color = '#888';
          }
        });

        // Pass 2: ALL text nodes (catches non-leaf cases)
        const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
        while (walker.nextNode()) {
          const node = walker.currentNode;
          if (node.textContent && hasPII(node.textContent)) {
            node.textContent = applyRedaction(node.textContent);
          }
        }

  // page.frames() already includes all same-origin child iframes as separate
  // Frame objects, so the outer loop handles them — no manual iframe walk needed.
      }, { patterns: serializedPatterns, matchers: matchStrings });
    } catch { }
  }
}

async function openAndScreenshot(url: string, filename: string): Promise<void> {
  const page = await context.newPage();
  await page.goto(url);
  await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
  await handleAccountPicker(page);
  await waitForPortalReady(page);
  await redactPII(page);
  await page.screenshot({ path: path.join(outputDir, filename), fullPage: false });
  await page.close();
}

// ── Tests ──────────────────────────────────────────────────

test.describe.configure({ mode: 'serial' });

test.describe('Act 1 — The Vault', () => {

  test('1.1 Storage account overview (HNS)', async () => {
    await openAndScreenshot(`${storageBase(STORAGE_ACCOUNT_HNS)}/overview`, '01-hns-overview.png');
  });

  test('1.2 Networking — Private endpoints (HNS)', async () => {
    await openAndScreenshot(`${storageBase(STORAGE_ACCOUNT_HNS)}/networking`, '02-hns-networking.png');
  });

  test('1.3 Containers (HNS)', async () => {
    await openAndScreenshot(`${storageBase(STORAGE_ACCOUNT_HNS)}/containersList`, '03-hns-containers.png');
  });

  test('1.4 Immutability policy (HNS)', async () => {
    const page = await context.newPage();
    await page.goto(`${storageBase(STORAGE_ACCOUNT_HNS)}/containersList`);
    await page.waitForLoadState('networkidle', { timeout: 60_000 }).catch(() => {});
    await handleAccountPicker(page);
    await waitForPortalReady(page);
    const container = page.getByText('forensic-evidence').first();
    if (await container.isVisible()) {
      await container.click();
      await page.waitForLoadState('networkidle', { timeout: 30_000 }).catch(() => {});
      await waitForPortalReady(page);
    }
    await redactPII(page);
    await page.screenshot({ path: path.join(outputDir, '04-hns-immutability.png'), fullPage: false });
    await page.close();
  });

  test('1.5 Defender for Storage', async () => {
    await openAndScreenshot(`${storageBase(STORAGE_ACCOUNT_HNS)}/defenderForStorage`, '05-defender-storage.png');
  });

});

test.describe('Act 5 — The Audit', () => {

  test('5.1 Diagnostic settings — StorageBlobLogs pipeline', async () => {
    const diagUrl = `${storageBase(STORAGE_ACCOUNT_HNS)}/diagnostics`;
    await openAndScreenshot(diagUrl, '06-diagnostic-settings.png');
  });

});

test.describe('Act 7 — The Lifecycle', () => {

  test('7.1 Lifecycle management rules (HNS)', async () => {
    await openAndScreenshot(`${storageBase(STORAGE_ACCOUNT_HNS)}/lifecycleManagement`, '07-hns-lifecycle.png');
  });

});

test.describe('Infrastructure — Function App', () => {

  test('Function app overview', async () => {
    const funcUrl = `${portalBase}/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Web/sites/${FUNCTION_APP}/overview`;
    await openAndScreenshot(funcUrl, '08-function-app.png');
  });

});
