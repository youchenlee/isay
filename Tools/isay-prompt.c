// 依 Whisper 實際 token 數，決定這次提示放得進哪些內容。
// 輸入：第一行是游標前文字（可空），其後每行一個候選提示詞，依優先順序排列。
// 輸出：第一行 1／0 表示游標前文字是否放得進，其後每行一個選上的提示詞。
// whisper.cpp 只保留提示最後 n_text_ctx/2 - 1 個 token，超出時會丟掉開頭的高優先詞，所以要先挑好。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <ggml-backend.h>
#include <whisper.h>

static void quiet(enum ggml_log_level level, const char *text, void *data) { (void)level; (void)text; (void)data; }

static int count_of(struct whisper_context *ctx, const char *text) { return whisper_token_count(ctx, text); }

static ssize_t read_line(char **line, size_t *size) {
    ssize_t got = getline(line, size, stdin);
    if (got > 0 && (*line)[got - 1] == '\n') (*line)[--got] = 0;
    return got;
}

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: isay-prompt BACKEND_DIR MODEL < context-and-terms\n"); return 2; }
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

    char *line = NULL;
    size_t size = 0;
    char context[2048] = "";
    ssize_t got = read_line(&line, &size);
    if (got > 0 && (size_t)got < sizeof context) memcpy(context, line, (size_t)got + 1);
    const int keep_context = context[0] && count_of(ctx, context) <= limit;
    if (!keep_context) context[0] = 0;
    printf("%d\n", keep_context);

    const size_t cap = 1 << 16;
    char *hints = calloc(cap, 1), *prompt = calloc(cap + sizeof context + 8, 1);
    if (!hints || !prompt) return 1;
    size_t len = 0;
    while ((got = read_line(&line, &size)) >= 0) {
        if (got == 0) continue;
        if (len + (size_t)got + 8 >= cap) break;
        const size_t base = len;
        if (len) { memcpy(hints + len, "、", 3); len += 3; }
        memcpy(hints + len, line, (size_t)got);
        len += (size_t)got;
        hints[len] = 0;
        snprintf(prompt, cap + sizeof context + 8, "%s。%s", hints, context);
        const int used = count_of(ctx, prompt);
        if (used < 0 || used > limit) { len = base; hints[len] = 0; continue; }
        printf("%s\n", line);
    }
    whisper_free(ctx);
    return 0;
}
