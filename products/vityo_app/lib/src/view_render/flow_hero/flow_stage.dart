/// The stage: the hero canvas from the flow-hero mock — dotted grid, sagging
/// cables with flowing hot leads, and draggable node cards. Tapping a card
/// selects it and opens the source dock; dragging the background pans.
library;

import 'package:flutter/material.dart';

import 'controller.dart';
import 'hero_board.dart';

class FlowStage extends StatelessWidget {
  const FlowStage({super.key, required this.controller});

  final FlowHeroController controller;

  @override
  Widget build(BuildContext context) {
    return ClipRect(child: HeroBoard(controller: controller));
  }
}
