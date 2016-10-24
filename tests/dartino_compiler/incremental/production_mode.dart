// Copyright (c) 2016, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library tests.dartino_compiler.incremental.production_mode;

import 'dartino_vm_tester.dart' show
    compileAndRun;

import 'package:dartino_compiler/src/dartino_compiler_options.dart' show
    IncrementalMode;

import 'common.dart';

class ProductionModeTestSuite extends IncrementalTestSuite {
  const ProductionModeTestSuite()
      : super("production");

  Future<Null> run(String testName, EncodedResult encodedResult) {
    return compileAndRun(
        testName, encodedResult, incrementalMode: IncrementalMode.production);
  }
}

const ProductionModeTestSuite suite = const ProductionModeTestSuite();

/// Invoked by ../../dartino_tests/dartino_test_suite.dart.
Future<Map<String, NoArgFuture>> list() => suite.list();

Future<Null> main(List<String> arguments) => suite.runFromMain(arguments);
