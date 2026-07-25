// Плоский конфиг ESLint для Vue 3 + TypeScript.
// npm i -D eslint eslint-plugin-vue @typescript-eslint/parser typescript-eslint
import js from '@eslint/js'
import ts from 'typescript-eslint'
import vue from 'eslint-plugin-vue'

export default [
  js.configs.recommended,
  ...ts.configs.strict,
  ...vue.configs['flat/recommended'],
  {
    rules: {
      // Правила, соответствующие rules/10-components.md.
      // Каждое здесь — это правило из текста, ставшее проверкой.
      '@typescript-eslint/no-explicit-any': 'error',
      'vue/no-mutating-props': 'error',
      'vue/require-v-for-key': 'error',
      'vue/no-v-html': 'error',
      'vue/component-api-style': ['error', ['script-setup']],
      'vue/require-typed-ref': 'error',
      'vue/max-props': ['warn', { maxProps: 5 }],
      'max-lines': ['warn', { max: 200, skipBlankLines: true, skipComments: true }],
      'complexity': ['error', 12],
      'no-console': ['error', { allow: ['warn', 'error'] }]
    }
  }
]
