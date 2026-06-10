/* standalone_main.c — run-once driver for libunwind's libFuzzer harness.
 * Reads ONE input file and feeds it to LLVMFuzzerTestOneInput so a crashing
 * input can be replayed without the libFuzzer runtime. No instrumentation
 * dependency; built into <fuzzer>-standalone.
 */
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <input-file>\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "rb");
  if (!f) {
    fprintf(stderr, "failed to open %s\n", argv[1]);
    return 2;
  }
  fseek(f, 0, SEEK_END);
  long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 0) { fclose(f); return 3; }
  uint8_t *data = malloc((size_t)size ? (size_t)size : 1);
  if (!data) { fclose(f); return 3; }
  size_t r = fread(data, 1, (size_t)size, f);
  fclose(f);
  LLVMFuzzerTestOneInput(data, r);
  free(data);
  return 0;
}
