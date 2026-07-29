// Заготовка ESLint для правил std-js-base (плоский конфиг, ESLint 9+).
//
// Копируется в корень проекта. Здесь только то, что вытекает из правил
// модуля и проверяется машиной; стилевое оформление — задача форматтера,
// а не линтера.
//
//   npm i -D eslint @eslint/js eslint-plugin-import
//   npx eslint .
import js from '@eslint/js'
import importPlugin from 'eslint-plugin-import'

export default [
  js.configs.recommended,
  {
    plugins: { import: importPlugin },
    languageOptions: {
      ecmaVersion: 'latest',
      sourceType: 'module',
    },
    rules: {
      // 10-language: каждый await рассчитан на отказ, плавающих промисов нет
      'no-async-promise-executor': 'error',
      'require-atomic-updates': 'error',
      'no-return-await': 'error',

      // 10-language: сравнение строгое, значение по умолчанию через ??
      eqeqeq: ['error', 'always', { null: 'ignore' }],
      'no-implicit-coercion': 'error',

      // 10-language: мутация аргументов запрещена
      'no-param-reassign': ['error', { props: true }],

      // 10-language: console только через логгер с уровнями
      'no-console': ['error', { allow: ['warn', 'error'] }],

      // 20-modules: циклов нет, из чужих внутренностей не импортируем
      'import/no-cycle': ['error', { maxDepth: Infinity }],
      'import/no-self-import': 'error',
      'import/no-useless-path-segments': 'error',
      'import/no-extraneous-dependencies': 'error',

      // 20-modules: именованные экспорты вместо default
      'import/no-default-export': 'error',
      'import/no-mutable-exports': 'error',

      // 30-errors: catch без обработки запрещён
      'no-empty': ['error', { allowEmptyCatch: false }],
      'no-ex-assign': 'error',
      'no-unsafe-finally': 'error',

      // 30-errors: бросаем ошибки, а не строки — иначе теряется стек
      'no-throw-literal': 'error',
      'prefer-promise-reject-errors': 'error',
    },
  },
  {
    // Точки входа фреймворков и конфиги требуют default-экспорт по контракту
    files: ['**/*.config.{js,ts}', '**/pages/**', '**/layouts/**', '**/middleware/**'],
    rules: { 'import/no-default-export': 'off' },
  },
]
