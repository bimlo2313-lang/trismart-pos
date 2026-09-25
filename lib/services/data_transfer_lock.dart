// Satu operasi backup/restore, termasuk saat preview restore menunggu konfirmasi.
class DataTransferLock {
  static bool _busy = false;
  static bool acquire() {
    if (_busy) return false;
    _busy = true;
    return true;
  }

  static void release() => _busy = false;
}
