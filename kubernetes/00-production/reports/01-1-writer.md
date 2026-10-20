Сомнительные места 01-1:
- Лаба 1 шаг 1: вывод -v=6 сокращён; grep '"Response"'; cm2.yaml через --dry-run=client — новое. Шаги 3–4: числа 4306/4307 реальные, порядок шагов изменён.
- Лаба 2 шаг 1: jq-фильтр и watch.json с pid-файлом — новые, вывод в JSON вместо формата Python старого прогона (типы событий и версии 4336/4338 реальные). Шаг 2: 410 «too old resource version: 10 (2942)» реальное.
- Лаба 3: get pods -o wide сокращён; шаг 4 SECONDS-замер (21 с, ~15 с lease — из старой части); шаг 6 crictl ps -a сокращён, kill -9 $PID; шаг 7 переменная P.
- «Риски» лабы 3: «короткий всплеск CPU» — оценка.
- §3: «kubelet замечает изменение за секунды» (file-check-frequency не назван — по умолчанию 20 с).
- §4: /readyz?verbose, /livez — из знаний.
- §6: leader election 15/10/2 с; compaction каждые 5 мин; consistent reads from cache «с 1.31» — проверить статус в 1.36 (GA?); NotReady ~50 с, 300 с; токен 1 ч.
- Учесть исследование: APF и 429, пределы масштаба (план §4), WatchList/streaming list, coordinated leader election.
