# Только для запуска общих хуков из Python-переходника; BASH_ENV не устанавливается глобально.
if [ -n "${SYSADMIN_PYTHON:-}" ]; then
    python3() { "$SYSADMIN_PYTHON" "$@"; }
    export -f python3
fi
