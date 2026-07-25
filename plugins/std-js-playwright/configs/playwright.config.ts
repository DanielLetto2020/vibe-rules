import { defineConfig, devices } from '@playwright/test'

// Конфиг, делающий падения разбираемыми, а прогон — воспроизводимым.
export default defineConfig({
  testDir: './e2e',
  fullyParallel: true,
  // Забытый test.only не должен молча сузить прогон в CI до одного теста
  forbidOnly: !!process.env.CI,
  // Ретрай — не лечение флака, а способ не блокировать CI, пока флак чинят.
  // Локально ретраев нет: тест должен падать сразу и честно.
  retries: process.env.CI ? 2 : 0,
  workers: process.env.CI ? 2 : undefined,
  reporter: process.env.CI ? [['github'], ['html']] : 'list',
  use: {
    baseURL: process.env.BASE_URL ?? 'http://localhost:3000',
    // Без этих трёх строк разбор падения в CI невозможен
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    actionTimeout: 10_000
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: '.auth/user.json' },
      dependencies: ['setup']
    }
  ],
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
    reuseExistingServer: !process.env.CI
  }
})
