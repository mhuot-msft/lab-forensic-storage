import { defineConfig } from '@playwright/test';
import path from 'path';

/**
 * Playwright config — browser launch is handled in the spec file
 * via launchPersistentContext with a copy of the Edge profile.
 */
export default defineConfig({
  testDir: '.',
  testMatch: 'validate-portal.spec.ts',
  timeout: 120_000,
  retries: 1,
  outputDir: path.join(__dirname, '..', '..', 'validation-output', '.playwright-artifacts'),
});
