import 'package:file_picker/file_picker.dart';
// ignore: depend_on_referenced_packages
import 'package:file_picker_web/file_picker_web.dart';

WebOptions localFilePickerOptions() =>
    // Disable preloading so the page can enforce the size cap before reading.
    // ignore: deprecated_member_use
    const FilePickerWebOptions(withData: false);
