// 讀入候選提示詞（每行一個），依 Whisper 實際 token 數挑選放得進提示的詞。
// whisper.cpp 只保留提示最後 n_text_ctx/2 - 1 個 token，超出時會丟掉開頭的高優先詞。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <ggml-backend.h>
#include <whisper.h>

static void quiet(enum ggml_log_level level, const char *text, void *data) { (void)level; (void)text; (void)data; }

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: isay-prompt BACKEND_DIR MODEL < terms\n"); return 2; }
    whisper_log_set(quiet, NULL);
    // 只需要分詞器：只載入 CPU 後端，避開 Metal 每次換路徑都要重新編譯的啟動成本。
    DIR *dir = opendir(argv[1]);
    if (!dir) return 1;
    for (struct dirent *entry; (entry = readdir(dir));) {
        if (strncmp(entry->d_name, "libggml-cpu", 11) != 0) continue;
        char path[4096];
        snprintf(path, sizeof path, "%s/%s", argv[1], entry->d_name);
        ggml_backend_load(path);
    }
    closedir(dir);
    struct whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    struct whisper_context *ctx = whisper_init_from_file_with_params_no_state(argv[2], params);
    if (!ctx) return 1;
    const int limit = whisper_n_text_ctx(ctx) / 2 - 1;
    size_t cap = 1 << 16, len = 0;
    char *prompt = calloc(cap, 1), *line = NULL;
    size_t n = 0;
    ssize_t got;
    int used = 0;
    while ((got = getline(&line, &n, stdin)) > 0) {
        if (line[got - 1] == '\n') line[--got] = 0;
        if (got == 0) continue;
        size_t base = len;
        if (len + got + 8 >= cap) break;
        if (len) { memcpy(prompt + len, "、", 3); len += 3; }
        memcpy(prompt + len, line, got); len += got;
        memcpy(prompt + len, "。", 4);
        int tokens = whisper_token_count(ctx, prompt);
        if (tokens < 0 || tokens > limit) { len = base; prompt[len] = 0; continue; }
        prompt[len] = 0;
        printf("%s\n", line);
        used = tokens;
    }
    fprintf(stderr, "tokens %d limit %d\n", used, limit);
    whisper_free(ctx);
    return 0;
}
