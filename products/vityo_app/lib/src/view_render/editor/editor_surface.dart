import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../view_ide/interaction/interaction.dart';
import '../../view_ide/language/language_contract.dart';
import '../platform/viewport_profile.dart';
import '../../ide/editor/document_state.dart';
import '../../ide/editor/editor_controller.dart';
import '../../ide/editor/render_plan/render_plan.dart';
import '../../ide/editor/performance/rendered_input_performance_protocol.dart';
import '../../ide/editor/selection_state.dart';
import 'editor_text_style_binding.dart';
import 'editor_text_input_client.dart';

part 'editor_surface_shell.dart';
part 'editor_source_pane.dart';
part 'editor_language_inspector.dart';
part 'editor_render_pipeline.dart';
part 'editor_high_volume_viewport.dart';
