"""TRISMART Master Converter GUI.

Lightweight tkinter GUI for converting Excel .xls master files to safe CSV.
Reuses the validated converter engine from convert_master.py.
"""

import queue
import sys
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
import os
from typing import Optional

# Import the converter module - resolve relative to this file's location
BASE_DIR = Path(__file__).resolve().parent
if str(BASE_DIR) not in sys.path:
    sys.path.insert(0, str(BASE_DIR))

import convert_master as converter


class ConversionWorker(threading.Thread):
    """Background thread for conversion using the validated engine directly."""

    def __init__(self, source_path: Path, output_path: Path, result_queue: queue.Queue):
        super().__init__()
        self.source_path = source_path
        self.output_path = output_path
        self.result_queue = result_queue
        self.daemon = False  # Non-daemon to ensure cleanup

    def run(self):
        try:
            # Call converter directly - it returns (return_code, stats)
            return_code, stats = converter.convert(self.source_path, self.output_path)
            self.result_queue.put(("done", return_code, stats, None))
        except Exception as e:
            self.result_queue.put(("error", None, None, str(e)))
class MasterConverterGUI:
    """Main GUI application."""

    def __init__(self, root: tk.Tk):
        self.root = root
        self.root.title("TRISMART Master Converter")
        self.root.resizable(False, False)

        # Fixed window size
        self.width, self.height = 520, 540
        self._center_window()

        # State
        self.source_file: Optional[Path] = None
        self.output_file: Optional[Path] = None
        self.worker: Optional[ConversionWorker] = None
        self.result_queue: queue.Queue = queue.Queue()

        # UI setup
        self._create_widgets()
        self._set_initial_state()

        # Start polling for worker results
        self._poll_queue()

        # Handle window close
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _center_window(self):
        sw, sh = self.root.winfo_screenwidth(), self.root.winfo_screenheight()
        x = (sw - self.width) // 2
        y = (sh - self.height) // 2
        self.root.geometry(f"{self.width}x{self.height}+{x}+{y}")

    def _create_widgets(self):
        # Main container with padding
        main = ttk.Frame(self.root, padding=20)
        main.pack(fill="both", expand=True)

        # Header
        ttk.Label(main, text="TRISMART MASTER CONVERTER", font=("Segoe UI", 16, "bold")).pack(anchor="center")
        ttk.Label(main, text="Excel \u2192 CSV Master Barang", font=("Segoe UI", 9), foreground="gray").pack(anchor="center", pady=(0, 15))

        # File selection frame
        file_frame = ttk.LabelFrame(main, text="File Sumber", padding=15)
        file_frame.pack(fill="x", pady=(0, 15))

        self.source_label = ttk.Label(file_frame, text="Belum ada file dipilih", foreground="gray", wraplength=440)
        self.source_label.pack(anchor="w", fill="x")

        ttk.Button(file_frame, text="Pilih File Excel (.xls)", command=self._browse_file).pack(anchor="w", pady=(10, 0))

        # Progress bar (hidden initially)
        self.progress = ttk.Progressbar(main, mode="indeterminate", length=440)
        self.progress.pack(fill="x", pady=(0, 10))
        self.progress.pack_forget()

        # Convert button
        self.convert_btn = ttk.Button(main, text="KONVERSI", command=self._start_conversion, state="disabled")
        self.convert_btn.pack(fill="x", pady=(0, 10))

        # Result display
        result_frame = ttk.LabelFrame(main, text="Hasil", padding=10)
        result_frame.pack(fill="both", expand=True, pady=(0, 10))

        self.result_text = tk.Text(result_frame, height=10, width=55, font=("Consolas", 9), state="disabled", wrap="none")
        self.result_text.pack(fill="both", expand=True)

        # Open folder button
        self.open_folder_btn = ttk.Button(main, text="BUKA FOLDER HASIL", command=self._open_output_folder, state="disabled")
        self.open_folder_btn.pack(fill="x", pady=(0, 15))

        # Footer
        footer = ttk.Frame(main)
        footer.pack(fill="x", side="bottom", pady=(10, 0))
        ttk.Label(footer, text="Developed By Bimz", font=("Segoe UI", 8), foreground="gray").pack(anchor="center")
        ttk.Label(footer, text="Version 1.0.0", font=("Segoe UI", 8), foreground="gray").pack(anchor="center")

    def _set_initial_state(self):
        self.source_file = None
        self.output_file = None
        self.convert_btn.config(state="disabled", text="KONVERSI")
        self.open_folder_btn.config(state="disabled")
        self.progress.stop()
        self.progress.pack_forget()
        self._update_result("Pilih file .xls untuk memulai konversi.", is_error=False)

    def _browse_file(self):
        path = filedialog.askopenfilename(
            title="Pilih File Excel (.xls)",
            filetypes=[("Excel Files", "*.xls"), ("All Files", "*.*")],
            defaultextension=".xls",
        )
        if path:
            self.source_file = Path(path)
            self.output_file = self.source_file.parent / "master_barang_safe.csv"
            self.source_label.config(text=str(self.source_file), foreground="black")
            self.convert_btn.config(state="normal")
            self._update_result("File dipilih. Klik KONVERSI untuk memulai.", is_error=False)

    def _start_conversion(self):
        if not self.source_file:
            return

        # Disable controls during conversion
        self.convert_btn.config(state="disabled", text="Mengonversi...")
        self.open_folder_btn.config(state="disabled")
        # Disable file selection too
        for child in self.root.winfo_children():
            self._disable_widget_tree(child)

        self.progress.pack(fill="x", pady=(0, 10), before=self.convert_btn)
        self.progress.start(10)
        self._update_result("Sedang mengonversi... Mohon tunggu.", is_error=False)

        # Start worker thread
        self.result_queue = queue.Queue()
        self.worker = ConversionWorker(self.source_file, self.output_file, self.result_queue)
        self.worker.start()

    def _disable_widget_tree(self, widget):
        """Recursively disable widgets except progress and result text."""
        if widget in (self.progress, self.result_text):
            return
        try:
            widget.config(state="disabled")
        except tk.TclError:
            pass
        for child in widget.winfo_children():
            self._disable_widget_tree(child)

    def _enable_widget_tree(self, widget):
        """Recursively enable widgets."""
        if widget in (self.progress,):
            return
        try:
            widget.config(state="normal")
        except tk.TclError:
            pass
        for child in widget.winfo_children():
            self._enable_widget_tree(child)

    def _poll_queue(self):
        """Check for worker completion."""
        try:
            msg_type, return_code, stats, error = self.result_queue.get_nowait()
            if msg_type == "done":
                self._on_conversion_done(return_code, stats)
            elif msg_type == "error":
                self._on_conversion_error(error)
        except queue.Empty:
            pass
        self.root.after(100, self._poll_queue)

    def _on_conversion_done(self, return_code: int, stats: Optional[dict]):
        self.progress.stop()
        self.progress.pack_forget()
        self._enable_widget_tree(self.root)

        if return_code == 0 and stats is not None:
            self._show_success(stats)
        else:
            self._show_error("Konversi gagal. Lihat detail error di file laporan.")

    def _on_conversion_error(self, error_msg: str):
        self.progress.stop()
        self.progress.pack_forget()
        self._enable_widget_tree(self.root)
        self._show_error(f"Kesalahan tak terduga: {error_msg}")

    def _show_success(self, stats: dict):
        self.convert_btn.config(state="normal", text="KONVERSI")
        self.open_folder_btn.config(state="normal")

        # Use actual stats keys from converter
        lines = [
            f"File          : {self.output_file.name if self.output_file else '-'}",
            f"Total baris   : {stats.get('CSV rows', stats.get('XLS rows', '-'))}",
            f"PLU unik      : {stats.get('CSV PLU unik', stats.get('XLS PLU unik', '-'))}",
            f"Barcode terisi: {stats.get('CSV barcode terisi', stats.get('XLS barcode terisi', '-'))}",
            f"Barcode kosong: {stats.get('CSV barcode kosong', stats.get('XLS barcode kosong', '-'))}",
            f"Error         : {stats.get('Error', stats.get('Barcode mismatch', 0))}",
            "",
            "STATUS: VALID",
        ]
        self._update_result("\n".join(lines), is_error=False)
        self.source_label.config(text=str(self.source_file), foreground="green")

    def _show_error(self, message: str):
        self.convert_btn.config(state="normal", text="KONVERSI")
        self.open_folder_btn.config(state="disabled")

        lines = [
            f"File: {self.output_file.name if self.output_file else '-'}",
            f"ERROR: {message}",
            "",
            "STATUS: GAGAL",
        ]
        self._update_result("\n".join(lines), is_error=True)
        self.source_label.config(text="Kesalahan konversi", foreground="red")

    def _update_result(self, text: str, is_error: bool):
        self.result_text.config(state="normal")
        self.result_text.delete("1.0", tk.END)
        self.result_text.insert("1.0", text)
        self.result_text.config(state="disabled", fg="red" if is_error else "black")

    def _open_output_folder(self):
        if self.output_file and self.output_file.parent.exists():
            try:
                os.startfile(str(self.output_file.parent))
            except Exception:
                messagebox.showerror("Error", "Tidak dapat membuka folder output.")

    def _on_close(self):
        if self.worker and self.worker.is_alive():
            if messagebox.askokcancel("Konversi Berjalan", "Konversi masih berjalan. Yakin ingin menutup?"):
                self.root.destroy()
        else:
            self.root.destroy()


def main():
    root = tk.Tk()
    MasterConverterGUI(root)
    root.mainloop()


if __name__ == "__main__":
    main()