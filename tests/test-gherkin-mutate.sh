#!/usr/bin/env bash
# test-gherkin-mutate.sh — тесты мутации данных спецификации.
#
# Проверяется главное свойство: инструмент отличает тест, читающий
# спецификацию, от теста с захардкоженными значениями. Второй проходит любую
# мутацию кода и при этом не связан с требованием — именно это и ловится.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$ROOT/tests/require.sh"; require_tools jq python3
MUT="$ROOT/plugins/std-gauntlet/scripts/gherkin-mutate.py"
PASS=0; FAIL=0
ok()  { printf '  \033[32mOK\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
P="$TMP/proj"; mkdir -p "$P/features"

cat > "$P/features/discount.feature" <<'EOF'
Функция: Скидка

  Сценарий: скидка десять процентов
    Дано заказ на 1000 рублей
    Тогда итоговая сумма равна 900 рублей
    И статус заказа "ожидает оплаты"
EOF

# Читает из спецификации ВСЕ значения, которые в ней есть: и числа, и статус.
# Неполный тест дал бы выжившего мутанта — и был бы прав, потому что часть
# требования он действительно не проверяет.
cat > "$P/honest.py" <<'PYEOF'
import re, sys, pathlib
txt = pathlib.Path("features/discount.feature").read_text()
nums = [int(n) for n in re.findall(r'(\d+) рублей', txt)]
status = re.search(r'статус заказа "([^"]+)"', txt)
if len(nums) != 2 or not status:
    sys.exit(1)
order, total = nums
ok_sum = total == order - order * 10 // 100
ok_status = status.group(1) == "ожидает оплаты"
sys.exit(0 if ok_sum and ok_status else 1)
PYEOF

# Спецификацию не открывает: значения захардкожены
cat > "$P/fake.py" <<'PY'
import sys
order, total = 1000, 900
sys.exit(0 if total == order - 100 else 1)
PY

cd "$P" || exit 1

echo "== находит значения для порчи =="
OUT=$(python3 "$MUT" --dry-run 2>&1)
grep -q 'Нашлось мутаций' <<<"$OUT" && ok "мутации найдены" || bad "поиск" "ничего не нашлось"
grep -q '1001' <<<"$OUT" && ok "число сдвигается на единицу — ловит границы" || bad "сдвиг числа" "нет"
grep -q 'заказ на 0 рублей' <<<"$OUT" && ok "число обнуляется — ловит пустой случай" || bad "обнуление" "нет"
grep -qE 'ЗАВЕДОМО-ДРУГОЕ|DEFINITELY-OTHER' <<<"$OUT" && ok "значение в кавычках подменяется" || bad "подмена строки" "нет"

echo "== отличает честный тест от имитации =="
python3 "$MUT" --run "python3 honest.py" --json > "$TMP/honest.json" 2>/dev/null
HS=$(jq -r '.score' "$TMP/honest.json" 2>/dev/null)
[[ "$HS" == "100" ]] && ok "тест, читающий спецификацию: score 100%" || bad "честный тест" "score $HS вместо 100"

python3 "$MUT" --run "python3 fake.py" --json > "$TMP/fake.json" 2>/dev/null
FS=$(jq -r '.score' "$TMP/fake.json" 2>/dev/null)
[[ "$FS" == "0" ]] && ok "тест с захардкоженными данными: score 0%" || bad "имитация" "score $FS вместо 0"

SURV=$(jq -r '.survived | length' "$TMP/fake.json" 2>/dev/null)
[[ "$SURV" -gt 0 ]] && ok "выжившие мутанты перечислены с местом и значением" || bad "отчёт" "список пуст"
jq -e '.survived[0] | has("original") and has("mutated") and has("where")' "$TMP/fake.json" >/dev/null 2>&1 \
  && ok "в отчёте видно, что было и что стало" || bad "детали мутанта" "полей не хватает"

echo "== спецификация не остаётся испорченной =="
ORIG=$(md5sum features/discount.feature | cut -d' ' -f1)
python3 "$MUT" --run "python3 fake.py" >/dev/null 2>&1
AFTER=$(md5sum features/discount.feature | cut -d' ' -f1)
[[ "$ORIG" == "$AFTER" ]] && ok "файл восстановлен после прогона" || bad "восстановление" "файл изменён"

echo "== прерванный прогон не оставляет спецификацию испорченной =="
# Bash-инструмент по таймауту шлёт SIGTERM. finally при этом не выполнялся,
# и в спецификации оставалось «Дано заказ на 1001 рублей».
cp features/discount.feature "$TMP/discount.orig"
cat > "$P/slow.sh" <<SH
#!/usr/bin/env bash
# Исходная спецификация — быстро и зелено, испорченная — долго
cmp -s features/discount.feature "$TMP/discount.orig" && exit 0
sleep 30
SH
wait_mutated() { # ждём, пока файл испорчен (до 10 секунд)
  local _
  for _ in $(seq 1 100); do
    cmp -s features/discount.feature "$TMP/discount.orig" || return 0
    sleep 0.1
  done
  return 1
}
python3 "$MUT" --run "bash slow.sh" >/dev/null 2>&1 &
pid=$!
wait_mutated; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
cmp -s features/discount.feature "$TMP/discount.orig" \
  && ok "SIGTERM: спецификация восстановлена" || bad "SIGTERM" "файл испорчен: $(grep -n 'заказ на' features/discount.feature)"
cp "$TMP/discount.orig" features/discount.feature

# SIGKILL не перехватить. Копия исходника лежит рядом, и следующий запуск
# возвращает её на место прежде всего остального.
python3 "$MUT" --run "bash slow.sh" >/dev/null 2>&1 &
pid=$!
wait_mutated; kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
OUT=$(python3 "$MUT" --dry-run 2>&1)
cmp -s features/discount.feature "$TMP/discount.orig" \
  && ok "после SIGKILL следующий запуск восстанавливает спецификацию" \
  || bad "SIGKILL" "файл испорчен: $(grep -n 'заказ на' features/discount.feature)"
grep -q "восстановлен" <<<"$OUT" && ok "о восстановлении сказано вслух" || bad "SIGKILL: текст" "«восстановлен»"
[[ -z "$(find features -name '*gherkin-mutate*')" ]] && ok "копия после восстановления убрана" \
  || bad "SIGKILL: копия" "$(find features -name '*gherkin-mutate*')"
cp "$TMP/discount.orig" features/discount.feature; rm -f "$P/slow.sh"
sleep 0.2

echo "== все значения строки, включая колонки примеров =="
# Портилось только первое число строки: в «| 1000 | 900 |» колонка ожидаемого
# результата не трогалась, и тест с захардкоженным итогом получал 100%.
EX="$TMP/examples"; mkdir -p "$EX/features"
cat > "$EX/features/outline.feature" <<'EOF'
Функция: Скидка

  Структура сценария: скидка десять процентов
    Дано заказ на <order> рублей
    Тогда итоговая сумма равна <total> рублей

    Примеры:
      | order | total |
      | 1000  | 900   |
EOF
# Читает из примера сумму заказа, итог держит в себе
cat > "$EX/half.py" <<'PY'
import re, sys, pathlib
rows = [l for l in pathlib.Path("features/outline.feature").read_text().splitlines()
        if re.match(r"\s*\|\s*\d", l)]
order = int(rows[0].split("|")[1])
sys.exit(0 if order == 1000 and 900 == order - order // 10 else 1)
PY
( cd "$EX" && python3 "$MUT" --run "python3 half.py" --json ) > "$TMP/half.json" 2>/dev/null
HS=$(jq -r '.score' "$TMP/half.json" 2>/dev/null)
[[ -n "$HS" && "$HS" != "100" ]] && ok "итог в колонке примера портится — захардкоженный итог выжил (score $HS%)" \
  || bad "колонка примера" "score ниже 100, получили $HS"
jq -e '[.survived[] | select(.mutated | test("1000 +\\| +(901|0) "))] | length > 0' "$TMP/half.json" >/dev/null 2>&1 \
  && ok "выжившие мутанты — именно в колонке итога" || bad "колонка итога" "$(jq -c '.survived' "$TMP/half.json")"

echo "== отказы понятны, а не молчаливы =="
python3 "$MUT" --features nowhere --run "true" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "нет спецификаций — код 2, а не «всё хорошо»" || bad "нет файлов" "код не 2"

python3 "$MUT" --run "" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "не задана команда прогона — код 2" || bad "нет команды" "код не 2"

# Красные тесты до мутаций делают результат бессмысленным: любая мутация
# «убита» по причине, к ней не относящейся
python3 "$MUT" --run "false" >/dev/null 2>&1
[[ $? -eq 2 ]] && ok "тесты красные до мутаций — прогон отменяется" || bad "красная база" "код не 2"

echo "== сценарий без конкретных значений =="
mkdir -p "$TMP/vague/features"; cd "$TMP/vague" || exit 1
cat > features/vague.feature <<'EOF'
Функция: Заказ

  Сценарий: корректный заказ
    Дано корректный заказ
    Тогда операция проходит успешно
EOF
OUT=$(python3 "$MUT" --run "true" 2>&1)
grep -q 'не нашлось значений' <<<"$OUT" \
  && ok "сценарий без значений: объясняет, что портить нечего" \
  || bad "расплывчатый сценарий" "нет объяснения"

echo "== разведение с мутацией кода в строю проверок =="
# Имя гейта содержит слово mutation, и раньше под него подпадал храповик:
# он искал в выводе mutation score чужого формата и печатал «не удалось
# извлечь». Мутация данных под храповик не идёт — послаблений тут нет.
GA="$ROOT/plugins/std-gauntlet/scripts/gauntlet.sh"
mkdir -p "$P/.claude"
cat > "$P/.claude/gauntlet.json" <<'EOF'
{ "gates": { "spec-mutation": "python3 $STD_GAUNTLET_ROOT/scripts/gherkin-mutate.py --run 'python3 fake.py'" },
  "mutation": { "enabled": true, "mode": "ratchet", "floor": 0 } }
EOF
cd "$P" || exit 1
GOUT=$(CLAUDE_PROJECT_DIR="$P" bash "$GA" --only spec-mutation 2>&1)
grep -q 'не удалось извлечь' <<<"$GOUT" \
  && bad "храповик и мутация данных" "храповик вмешался в чужой гейт" \
  || ok "храповик не трогает мутацию данных"
grep -q 'ПРОВАЛ' <<<"$GOUT" \
  && ok "выживший мутант данных валит гейт" \
  || bad "вердикт гейта" "выжившие есть, а гейт зелёный"

rm -rf "$P/.claude"

echo
printf 'Пройдено: \033[32m%d\033[0m   Провалено: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
