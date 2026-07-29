---
paths:
  - "**/*.vue"
  - "components/**/*.{ts,js}"
  - "src/components/**/*.{ts,js}"
owner: "@frontend"
enforcement: lint
enforcement_ref:
  - configs/eslint.config.js
since: "2026-07-25"
---

# Vue 3: компоненты

- Только `<script setup lang="ts">`. Options API в новом коде не пишем.
- `defineProps` типизируем дженериком, без `any` и без `PropType<any>`.
  Пропс без типа — это `any`, просочившийся через границу компонента.
- Компонент не ходит в API напрямую: данные приходят через composable или store.
- Мутация пропса запрещена: наверх — событие через `defineEmits`.
- Побочные эффекты — в `onMounted`/`watch`, не в теле `setup`.
- `v-for` всегда с устойчивым `:key` (id сущности, не индекс массива).
- Ориентир: файл до 200 строк и до 5 пропсов. Больше — компонент делает
  слишком много, разбивай.
