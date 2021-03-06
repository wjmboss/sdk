// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

/// Handling of the communication with a dartino vm over a [VmConnection].
library dartino.vm_context;

import 'dart:async';

import 'dart:typed_data' show
    ByteData;

import 'dart:io' show
    File;

import 'package:persistent/persistent.dart' show
    Pair;

import 'vm_commands.dart';
import 'dartino_system.dart';

import 'incremental/dartino_compiler_incremental.dart' show
    IncrementalCompiler;

import 'src/debug_info.dart';

import 'debug_state.dart';

import 'src/shared_command_infrastructure.dart' show
    CommandTransformerBuilder,
    toUint8ListView;

import 'src/hub/session_manager.dart' show
    SessionState;

import 'program_info.dart' show
    Configuration,
    IdOffsetMapping,
    NameOffsetMapping;

import 'src/worker/developer.dart';
import 'src/diagnostic.dart';

import 'src/hub/exit_codes.dart' as exit_codes;

import 'src/vm_connection.dart' show
    VmConnection;

import 'program_info.dart' show
    IdOffsetMapping,
    NameOffsetMapping,
    ProgramInfoJson;

class SessionCommandTransformerBuilder
    extends CommandTransformerBuilder<Pair<int, ByteData>> {

  Pair<int, ByteData> makeCommand(int code, ByteData payload) {
    return new Pair<int, ByteData>(code, payload);
  }
}

// TODO(sigurdm): for now only the stdio and stderr events are actually
// notified.
abstract class DebugListener {
  // Notification that a new process has started.
  processStart(int processId) {}
  // Notification that a process is ready to run.
  processRunnable(int processId) {}
  // Notification that a process has exited.
  processExit(int processId) {}
  // A process has paused at start, before executing code.
  // This is sent on spawning processes.
  pauseStart(int processId) {}
  // An process has paused at exit, before terminating.
  pauseExit(int processId, BackTraceFrame topFrame) {}
  // A process has paused at a breakpoint or due to stepping.
  pauseBreakpoint(
      int processId, BackTraceFrame topFrame, Breakpoint breakpoint) {}
  // A process has paused due to interruption.
  pauseInterrupted(int processId, BackTraceFrame topFrame) {}
  // A process has paused due to an exception.
  pauseException(int processId, BackTraceFrame topFrame, RemoteObject thrown) {}
  // A process has started or resumed execution.
  resume(int processId) {}
  // A breakpoint has been added for a process.
  breakpointAdded(int processId, Breakpoint breakpoint) {}
  // A breakpoint has been removed.
  breakpointRemoved(int processId, Breakpoint breakpoint) {}
  // A garbage collection event.
  gc(int processId) {}
  // Notification of bytes written to stdout.
  writeStdOut(int processId, List<int> data) {}
  // Notification of bytes written stderr.
  writeStdErr(int processId, List<int> data) {}
  // The connection to the vm was lost.
  lostConnection() {}
  // The debugged program is over.
  terminated() {}
}

class SinkDebugListener extends DebugListener {
  final Sink stdoutSink;
  final Sink stderrSink;
  SinkDebugListener(this.stdoutSink, this.stderrSink);

  writeStdOut(int processId, List<int> data) {
    stdoutSink.add(data);
  }

  writeStdErr(int processId, List<int> data) {
    stderrSink.add(data);
  }
}

/// Encapsulates a connection to a running dartino-vm and provides a
/// [VmCommand] based view on top of it.
class DartinoVmContext {
  /// The connection to a dartino-vm.
  final VmConnection connection;

  /// The VM command reader reads data from the vm, converts the data
  /// into a [VmCommand], and provides a stream iterator iterating over
  /// these commands.
  /// If the [VmCommand] is for stdout or stderr the reader automatically
  /// forwards them to the stdout/stderr sinks and does not add them to the
  /// iterator.
  StreamIterator<Pair<int, ByteData>> _commandIterator;

  bool _drainedIncomingCommands = false;

  /// When true, don't use colors to highlight focus when printing code.
  /// This is currently only true when running tests to avoid having to deal
  /// with color control characters in the expected files.
  bool colorsDisabled = false;

  VmCommand connectionError = new ConnectionError("Connection is closed", null);

  final IncrementalCompiler compiler;
  final Future processExitCodeFuture;

  int interactiveExitCode = 0;

  DebugState debugState;
  DartinoSystem dartinoSystem;

  VmState vmState;

  bool get isSpawned => vmState != VmState.initial;
  bool get isScheduled {
    return vmState == VmState.running ||
      vmState == VmState.paused ||
      vmState == VmState.terminating;
  }
  bool get isPaused => vmState == VmState.paused;
  bool get isRunning => vmState == VmState.running;
  bool get isTerminated => vmState == VmState.terminated;

  /// The configuration of the vm connected to this session.
  Configuration configuration;

  /// `true` if the vm connected to this session is running from a snapshot.
  bool runningFromSnapshot;

  /// The hash of the snapshot in the vm connected to this session.
  ///
  /// Only valid if [runningFromSnapshot].
  int snapshotHash;

  IdOffsetMapping offsetMapping;

  Function translateMapObject = (MapId mapId, int index) => index;

  Function translateFunctionMessage = (int x) => x;

  Function translateClassMessage = (int x) => x;

  List<DebugListener> listeners = new List<DebugListener>();

  DartinoVmContext(
          VmConnection connection,
          this.compiler,
          [this.processExitCodeFuture])
      : connection = connection,
        _commandIterator =
            new StreamIterator<Pair<int, ByteData>>(connection.input.transform(
                new SessionCommandTransformerBuilder().build())) {
    connection.done.catchError((_, __) {}).then((_) {
      vmState = VmState.terminated;
    });

    // TODO(ajohnsen): Should only be initialized on debug()/testDebugger().
    debugState = new DebugState(this);
  }

  void notifyListeners(void f(DebugListener listener)) {
    listeners.forEach(f);
  }

  /// Convenience around [runCommands] for running just a single command.
  Future<VmCommand> runCommand(VmCommand command) {
    return runCommands([command]);
  }

  /// Sends the given commands to a dartino-vm and reads response commands
  /// (if necessary).
  ///
  /// If all commands have been successfully applied and responses been awaited,
  /// this function will complete with the last received [VmCommand] from the
  /// remote peer (or `null` if there was none).
  Future<VmCommand> runCommands(List<VmCommand> commands) async {
    if (commands.any((VmCommand c) => c.numberOfResponsesExpected == null)) {
      throw new ArgumentError(
          'The runComands() method will read response commands and therefore '
              'needs to know how many to read. One of the given commands does'
              'not specify how many commands the response will have.');
    }

    VmCommand lastResponse;
    for (VmCommand command in commands) {
      await sendCommand(command);
      for (int i = 0; i < command.numberOfResponsesExpected; i++) {
        lastResponse = await readNextCommand();
      }
    }
    return lastResponse;
  }

  /// Sends a [VmCommand] to a dartino-vm.
  Future sendCommand(VmCommand command) async {
    if (isTerminated) {
      throw new StateError(
          'Trying to send command ${command} to dartino-vm, but '
              'the connection is terminated');
    }
    command.addTo(connection.output, translateMapObject);
  }

  /// Will read the next [VmCommand] the dartino-vm sends to us.
  Future<VmCommand> readNextCommand({bool force: true}) async {
    VmCommand result = null;
    if (_drainedIncomingCommands) {
      return connectionError;
    }

    while (result == null) {

      _drainedIncomingCommands = !await _commandIterator.moveNext()
          .catchError((error, StackTrace trace) {
        connectionError = new ConnectionError(error, trace);
        return false;
      });

      if (_drainedIncomingCommands && force) {
        return connectionError;
      }

      Pair<int, ByteData> c = _commandIterator.current;

      if (c == null) return null;

      VmCommand command = new VmCommand.fromBuffer(
          VmCommandCode.values[c.fst], toUint8ListView(c.snd),
          translateFunctionMessage,
          translateClassMessage);
      if (command is StdoutData) {
        notifyListeners((DebugListener listener) {
          listener.writeStdOut(0, command.value);
        });
      } else if (command is StderrData) {
        notifyListeners((DebugListener listener) {
          listener.writeStdErr(0, command.value);
        });
      } else {
        result = command;
      }

    }
    return result;
  }

  /// Closes the connection to the dartino-vm and drains the remaining response
  /// commands.
  ///
  /// If [ignoreExtraCommands] is `false` it will throw a StateError if the
  /// dartino-vm sent any commands.
  Future shutdown({bool ignoreExtraCommands: false}) async {
    await connection.close().catchError((_) {});

    while (!_drainedIncomingCommands) {
      VmCommand response = await readNextCommand(force: false);
      if (!ignoreExtraCommands && response != null) {
        await kill();
        throw new StateError(
            "Got unexpected command from dartino-vm during shutdown "
                "($response)");
      }
    }
    vmState = VmState.terminated;
    notifyListeners((DebugListener listener) {
      listener.terminated();
    });
    return connection.done;
  }

  Future interrupt() {
    return sendCommand(const ProcessDebugInterrupt());
  }

  /// Closes the connection to the dartino-vm. It does not wait until it shuts
  /// down.
  ///
  /// This method will never complete with an exception.
  Future kill() async {
    vmState = VmState.terminated;
    _drainedIncomingCommands = true;
    await connection.close().catchError((_) {});
    var value = _commandIterator.cancel();
    if (value != null) {
      await value.catchError((_) {});
    }
    _drainedIncomingCommands = true;
  }

  Future applyDelta(DartinoDelta delta) async {
    VmCommand response = await runCommands(delta.commands);
    dartinoSystem = delta.system;
    return response;
  }

  Future<HandShakeResult> handShake(
      String version, {Duration maxTimeSpent: null}) async {
    Completer<VmCommand> completer = new Completer<VmCommand>();
    Timer timer;
    if (maxTimeSpent != null) {
      timer = new Timer(maxTimeSpent, () {
        if (!completer.isCompleted) {
          completer.completeError(
              new TimeoutException(
                  "No handshake reply from device", maxTimeSpent));
        }
      });
    }

    readNextCommand().then((VmCommand answer) {
      if (!completer.isCompleted) {
        completer.complete(answer);
      }
    });

    retryLoop() async {
      while (!completer.isCompleted) {
        sendCommand(new HandShake(version));
        if (maxTimeSpent == null) break;
        // TODO(sigurdm): The vm should allow several handshakes.
        await new Future.delayed(new Duration(seconds: 2));
      }
    }

    retryLoop();

    return completer.future.then((VmCommand value) {
      timer?.cancel();
      if (value is HandShakeResult) {
        return value;
      } else {
        return null;
      }
    });
  }

  Future disableVMStandardOutput() async {
    await runCommand(const DisableStandardOutput());
  }

  /// Returns either a [ProgramInfoCommand] or a [ConnectionError].
  Future<VmCommand> createSnapshot(
      {String snapshotPath: null}) async {
    VmCommand result = await runCommand(
        new CreateSnapshot(snapshotPath: snapshotPath));
    await shutdown();
    return result;
  }

  // Enable support for live-editing commands. This must be called prior to
  // sending deltas.
  Future enableLiveEditing() async {
    await runCommand(const LiveEditing());
  }

  // Enable support for debugging commands. This must be called prior to setting
  // breakpoints.
  Future<DebuggingReply> enableDebugging() async {
    VmCommand reply = await runCommand(const Debugging());
    if (reply == null || reply is! DebuggingReply) {
      throw new Exception("Expected a reply from the debugging command");
    }
    return reply;
  }

  Future spawnProcess(List<String> arguments) async {
    await runCommand(new ProcessSpawnForMain(arguments));
    vmState = VmState.spawned;
    notifyListeners((DebugListener listener) {
      listener.pauseStart(0);
      listener.processRunnable(0);
    });
  }

  /// Returns the [NameOffsetMapping] stored in the '.info.json' adjacent to a
  /// snapshot location.
  Future<NameOffsetMapping> getInfoFromSnapshotLocation(Uri snapshot) async {
    Uri info = snapshot.replace(path: "${snapshot.path}.info.json");
    File infoFile = new File.fromUri(info);

    if (!await infoFile.exists()) {
      await shutdown();
      throwFatalError(DiagnosticKind.infoFileNotFound, uri: info);
    }

    try {
      return ProgramInfoJson.decode(await infoFile.readAsString());
    } on FormatException {
      await shutdown();
      throwFatalError(DiagnosticKind.malformedInfoFile, uri: snapshot);
    }
  }

  Future<Null> initialize(
      SessionState state,
      {Uri snapshotLocation}) async {
    DebuggingReply debuggingReply = await enableDebugging();

    runningFromSnapshot = debuggingReply.isFromSnapshot;
    if (runningFromSnapshot) {
      snapshotHash = debuggingReply.snapshotHash;
      if (snapshotLocation == null) {
        snapshotLocation = defaultSnapshotLocation(state.script);
      }

      NameOffsetMapping nameOffsetMapping =
          await getInfoFromSnapshotLocation(snapshotLocation);

      if (nameOffsetMapping == null) {
        return exit_codes.COMPILER_EXITCODE_CRASH;
      }

      if (nameOffsetMapping.snapshotHash != snapshotHash) {
        await shutdown();
        throwFatalError(DiagnosticKind.snapshotHashMismatch,
            userInput: "${nameOffsetMapping.snapshotHash}",
            additionalUserInput: "${snapshotHash}",
            address: connection.description,
            uri: snapshotLocation);
      } else {

        dartinoSystem = state.compilationResults.last.system;

        offsetMapping = new IdOffsetMapping(
            dartinoSystem.computeSymbolicSystemInfo(
                state.compiler.compiler.libraryLoader.libraries),
            nameOffsetMapping);

        translateMapObject = (MapId mapId, int index) {
          if (mapId == MapId.methods) {
            return offsetMapping.offsetFromFunctionId(configuration, index);
          } else {
            return index;
          }
        };
        translateFunctionMessage = (int offset) {
          return offsetMapping.functionIdFromOffset(configuration, offset);
        };
        translateClassMessage = (int offset) {
          return offsetMapping.classIdFromOffset(configuration, offset);
        };
      }
    } else {
      enableLiveEditing();
      for (DartinoDelta delta in state.compilationResults) {
        await applyDelta(delta);
      }
    }

    if (!isSpawned) {
      await spawnProcess([]);
    }
  }

  Future terminate() async {
    await runCommand(const SessionEnd());
    if (processExitCodeFuture != null) await processExitCodeFuture;
    await shutdown();
  }

  // This method handles the various responses a command can return to indicate
  // the process has stopped running.
  // The session's state is updated to match the current state of the vm.
  Future<VmCommand> notifyListenersOfProcessStop(VmCommand response) async {
    switch (response.code) {
      case VmCommandCode.UncaughtException:
        RemoteObject thrown = await uncaughtException();
        notifyListeners((DebugListener listener) {
          listener.pauseException(
              debugState.currentProcess, debugState.topFrame, thrown);
        });
        break;

      case VmCommandCode.ProcessCompileTimeError:
        notifyListeners((DebugListener listener) {
          // TODO(sigurdm): Add processId and exception data.
          listener.pauseException(0, null, null);
        });
        break;

      case VmCommandCode.ProcessTerminated:
        notifyListeners((DebugListener listener) {
          // TODO(sigurdm): Communicate process id.
          listener.processExit(0);
        });
        break;

      case VmCommandCode.ConnectionError:
        notifyListeners((DebugListener listener) {
          listener.lostConnection();
        });
        break;

      case VmCommandCode.ProcessBreakpoint:
        ProcessBreakpoint command = response;
        Breakpoint bp = debugState.breakpoints[command.breakpointId];
        if (bp == null) {
          notifyListeners((DebugListener listener) {
            listener.pauseInterrupted(
                command.processId,
                debugState.topFrame);
          });
        } else {
          notifyListeners((DebugListener listener) {
            listener.pauseBreakpoint(
                command.processId,
                debugState.topFrame,
                bp);
          });
        }
        break;

      default:
        throw new StateError(
            "Unhandled response from Dartino VM connection: ${response.code}");

    }
    return response;
  }

  // This method handles the various responses a command can return to indicate
  // the process has stopped running.
  // The session's state is updated to match the current state of the vm.
  Future<VmCommand> handleProcessStop(VmCommand response) async {
    interactiveExitCode = exit_codes.COMPILER_EXITCODE_CRASH;
    debugState.reset();
    switch (response.code) {
      case VmCommandCode.UncaughtException:
        interactiveExitCode = exit_codes.DART_VM_EXITCODE_UNCAUGHT_EXCEPTION;
        vmState = VmState.terminating;
        UncaughtException command = response;
        debugState.currentProcess = command.processId;
        var function = dartinoSystem.lookupFunctionById(command.functionId);
        debugState.topFrame = new BackTraceFrame(
            function, command.bytecodeIndex, compiler, debugState);
        break;

      case VmCommandCode.ProcessCompileTimeError:
        interactiveExitCode = exit_codes.DART_VM_EXITCODE_COMPILE_TIME_ERROR;
        vmState = VmState.terminating;
        break;

      case VmCommandCode.ProcessTerminated:
        interactiveExitCode = 0;
        vmState = VmState.terminating;
        break;

      case VmCommandCode.ConnectionError:
        interactiveExitCode = exit_codes.COMPILER_EXITCODE_CONNECTION_ERROR;
        vmState = VmState.terminating;
        await shutdown();
        break;

      case VmCommandCode.ProcessBreakpoint:
        interactiveExitCode = 0;
        ProcessBreakpoint command = response;
        debugState.currentProcess = command.processId;
        var function = dartinoSystem.lookupFunctionById(command.functionId);
        debugState.topFrame = new BackTraceFrame(
            function, command.bytecodeIndex, compiler, debugState);
        vmState = VmState.paused;
        break;

      default:
        throw new StateError(
            "Unhandled response from Dartino VM connection: ${response.code}");

    }
    return response;
  }

  Future<VmCommand> startRunning() async {
    await sendCommand(const ProcessRun());
    vmState = VmState.running;
    notifyListeners((DebugListener listener) {
      listener.processStart(0);
    });
    notifyListeners((DebugListener listener) {
      listener.processRunnable(0);
    });
    notifyListeners((DebugListener listener) {
      listener.resume(0);
    });
    return notifyListenersOfProcessStop(
        await handleProcessStop(await readNextCommand()));
  }

  Future<Breakpoint> setBreakpointHelper(DartinoFunction function,
                             int bytecodeIndex) async {
    ProcessSetBreakpoint response = await runCommands([
        new PushFromMap(MapId.methods, function.functionId),
        new ProcessSetBreakpoint(bytecodeIndex),
    ]);
    int breakpointId = response.value;
    Breakpoint breakpoint =
        new Breakpoint(function, bytecodeIndex, breakpointId);
    debugState.breakpoints[breakpointId] = breakpoint;
    notifyListeners(
        (DebugListener listener) => listener.breakpointAdded(0, breakpoint));
    return breakpoint;
  }

  // TODO(ager): Let setBreakpoint return a stream instead and deal with
  // error situations such as bytecode indices that are out of bounds for
  // some of the methods with the given name.
  Future<List<Breakpoint>> setBreakpoint(
      {String methodName, int bytecodeIndex}) async {
    Iterable<DartinoFunction> functions =
        dartinoSystem.functionsWhere((f) => f.name == methodName);
    List<Breakpoint> breakpoints = [];
    for (DartinoFunction function in functions) {
      breakpoints.add(
          await setBreakpointHelper(function, bytecodeIndex));
    }
    return breakpoints;
  }

  Future<Breakpoint> setFileBreakpointFromPosition(String name,
                                       Uri file,
                                       int position) async {
    if (position == null) {
      return null;
    }
    DebugInfo debugInfo = compiler.debugInfoForPosition(
        file,
        position,
        dartinoSystem);
    if (debugInfo == null) {
      return null;
    }
    SourceLocation location = debugInfo.locationForPosition(position);
    if (location == null) {
      return null;
    }
    DartinoFunction function = debugInfo.function;
    int bytecodeIndex = location.bytecodeIndex;
    return setBreakpointHelper(function, bytecodeIndex);
  }

  Future<Breakpoint> setFileBreakpointFromPattern(Uri file,
                                      int line,
                                      String pattern) async {
    assert(line > 0);
    int position = compiler.positionInFileFromPattern(file, line - 1, pattern);
    return setFileBreakpointFromPosition(
        '$file:$line:$pattern', file, position);
  }

  Future<Breakpoint> setFileBreakpoint(Uri file, int line, int column) async {
    assert(line > 0 && column > 0);
    int position = compiler.positionInFile(file, line - 1, column - 1);
    return setFileBreakpointFromPosition('$file:$line:$column', file, position);
  }

  Future<Null> doDeleteOneShotBreakpoint(
      int processId, int breakpointId) async {
    ProcessDeleteBreakpoint response = await runCommand(
        new ProcessDeleteOneShotBreakpoint(processId, breakpointId));
    assert(response.id == breakpointId);
  }

  Future<Breakpoint> deleteBreakpoint(int id) async {
    assert(!isRunning && !isTerminated);
    if (!debugState.breakpoints.containsKey(id)) {
      return null;
    }
    ProcessDeleteBreakpoint response =
        await runCommand(new ProcessDeleteBreakpoint(id));
    assert(response.id == id);
    Breakpoint breakpoint = debugState.breakpoints.remove(id);
    notifyListeners((DebugListener listener) {
      listener.breakpointRemoved(0, breakpoint);
    });
    return breakpoint;
  }

  List<Breakpoint> breakpoints() {
    assert(debugState.breakpoints != null);
    return debugState.breakpoints.values.toList();
  }

  Iterable<Uri> findSourceFiles(Pattern pattern) {
    return compiler.findSourceFiles(pattern);
  }

  bool stepMadeProgress(BackTraceFrame frame) {
    return frame.functionId != debugState.topFrame.functionId ||
        frame.bytecodePointer != debugState.topFrame.bytecodePointer;
  }

  Future<VmCommand> _stepTo(int functionId, int bcp) async {
    assert(isPaused);
    VmCommand response = await runCommands([
      new PushFromMap(MapId.methods, functionId),
      new ProcessStepTo(bcp)]);
    return handleProcessStop(response);
  }

  Future<VmCommand> step() async {
    assert(isPaused);
    final SourceLocation previous = debugState.currentLocation;
    final BackTraceFrame initialFrame = debugState.topFrame;
    VmCommand response;
    do {
      int bcp = debugState.topFrame.stepBytecodePointer(previous);
      if (bcp != -1) {
        response = await _stepTo(debugState.topFrame.functionId, bcp);
      } else {
        response = await _stepBytecode();
      }
    } while (isPaused &&
             debugState.atLocation(previous) &&
             stepMadeProgress(initialFrame));
    return notifyListenersOfProcessStop(response);
  }

  Future<VmCommand> stepOver() async {
    assert(isPaused);
    VmCommand response;
    final SourceLocation previous = debugState.currentLocation;
    final BackTraceFrame initialFrame = debugState.topFrame;
    do {
      response = await _stepOverBytecode();
    } while (isPaused &&
             debugState.atLocation(previous) &&
             stepMadeProgress(initialFrame));
    return notifyListenersOfProcessStop(response);
  }

  Future<VmCommand> stepOut() async {
    assert(isPaused);
    BackTrace trace = await backTrace();
    // If we are at the last frame, just continue. This will either terminate
    // the process or stop at any user configured breakpoints.
    if (trace.visibleFrames <= 1) return cont();

    // Since we know there is at least two visible frames at this point stepping
    // out will hit a visible frame before the process terminates, hence we can
    // step out until we either hit another breakpoint or a visible frame, ie.
    // we skip internal frame and stop at the next visible frame.
    SourceLocation return_location = trace.visibleFrame(1).sourceLocation();
    VmCommand response;
    int processId = debugState.currentProcess;
    do {
      await sendCommand(const ProcessStepOut());
      ProcessSetBreakpoint setBreakpoint = await readNextCommand();
      assert(setBreakpoint.value != -1);

      // handleProcessStop resets the debugState and sets the top frame if it
      // hits either the above setBreakpoint or another breakpoint.
      response = await handleProcessStop(await readNextCommand());
      bool success =
          response is ProcessBreakpoint &&
          response.breakpointId == setBreakpoint.value;
      if (!success) {
        await doDeleteOneShotBreakpoint(processId, setBreakpoint.value);
        return response;
      }
    } while (!debugState.topFrame.isVisible);
    if (isPaused && debugState.atLocation(return_location)) {
      response = await step();
    }
    return notifyListenersOfProcessStop(response);
  }

  Future<VmCommand> restart() async {
    assert(isSpawned);
    assert(debugState.currentBackTrace != null);
    assert(debugState.currentBackTrace.length > 1);
    int frame = debugState.actualCurrentFrameNumber;
    return notifyListenersOfProcessStop(
        await handleProcessStop(await runCommand(new ProcessRestartFrame(frame))));
  }

  Future<VmCommand> stepBytecode() async {
    return notifyListenersOfProcessStop(await _stepBytecode());
  }

  Future<VmCommand> _stepBytecode() async {
    assert(isPaused);
    return handleProcessStop(await runCommand(const ProcessStep()));
  }

  Future<VmCommand> stepOverBytecode() async {
    return notifyListenersOfProcessStop(await _stepOverBytecode());
  }

  Future<VmCommand> _stepOverBytecode() async {
    assert(isPaused);
    int processId = debugState.currentProcess;
    await sendCommand(const ProcessStepOver());
    ProcessSetBreakpoint setBreakpoint = await readNextCommand();
    VmCommand response = await handleProcessStop(await readNextCommand());
    bool success =
        response is ProcessBreakpoint &&
        response.breakpointId == setBreakpoint.value;
    if (!success && isPaused && setBreakpoint.value != -1) {
      // Delete the initial one-time breakpoint as it wasn't hit.
      await doDeleteOneShotBreakpoint(processId, setBreakpoint.value);
    }
    return response;
  }

  Future<VmCommand> cont() async {
    assert(isPaused);
    notifyListeners((DebugListener listener) {
      listener.resume(0);
    });
    return notifyListenersOfProcessStop(
        await handleProcessStop(await runCommand(const ProcessContinue())));
  }

  bool selectFrame(int frame) {
    if (debugState.currentBackTrace == null ||
        debugState.currentBackTrace.actualFrameNumber(frame) == -1) {
      return false;
    }
    debugState.currentFrame = frame;
    return true;
  }

  BackTrace stackTraceFromBacktraceResponse(
      ProcessBacktrace backtraceResponse) {
    int frames = backtraceResponse.frames;
    BackTrace stackTrace = new BackTrace(frames, debugState);
    for (int i = 0; i < frames; ++i) {
      int functionId = backtraceResponse.functionIds[i];
      DartinoFunction function = dartinoSystem.lookupFunctionById(functionId);
      if (function == null) {
        function = const DartinoFunction.missing();
      }
      stackTrace.addFrame(
          compiler,
          new BackTraceFrame(function,
                         backtraceResponse.bytecodeIndices[i],
                         compiler,
                         debugState));
    }
    return stackTrace;
  }

  Future<RemoteObject> uncaughtException() async {
    assert(vmState == VmState.terminating);
    if (debugState.currentUncaughtException == null) {
      await sendCommand(const ProcessUncaughtExceptionRequest());
      debugState.currentUncaughtException = await readStructuredObject();
    }
    return debugState.currentUncaughtException;
  }

  Future<BackTrace> backTrace({int processId}) async {
    processId ??= debugState.currentProcess;
    assert(isSpawned);
    if (debugState.currentBackTrace == null) {
      ProcessBacktrace backtraceResponse =
          await runCommand(
              new ProcessBacktraceRequest(processId));
      debugState.currentBackTrace =
          stackTraceFromBacktraceResponse(backtraceResponse);
    }
    return debugState.currentBackTrace;
  }

  Future<BackTrace> backtraceForFiber(int fiber) async {
    ProcessBacktrace backtraceResponse =
        await runCommand(new ProcessFiberBacktraceRequest(fiber));
    return stackTraceFromBacktraceResponse(backtraceResponse);
  }

  Future<List<BackTrace>> fibers() async {
    assert(isRunning || isPaused);
    await runCommand(const NewMap(MapId.fibers));
    ProcessNumberOfStacks response =
        await runCommand(const ProcessAddFibersToMap());
    int numberOfFibers = response.value;
    List<BackTrace> stacktraces = new List(numberOfFibers);
    for (int i = 0; i < numberOfFibers; i++) {
      stacktraces[i] = await backtraceForFiber(i);
    }
    await runCommand(const DeleteMap(MapId.fibers));
    return stacktraces;
  }

  Future<List<int>> processes() async {
    assert(isSpawned);
    ProcessGetProcessIdsResult response =
      await runCommand(const ProcessGetProcessIds());
    return response.ids;
  }

  Future<BackTrace> processStack(int processId) async {
    assert(isPaused);
    ProcessBacktrace backtraceResponse =
      await runCommand(new ProcessBacktraceRequest(processId));
    return stackTraceFromBacktraceResponse(backtraceResponse);
  }

  Future<RemoteObject> readStructuredObject() async {
    VmCommand response = await readNextCommand();
    if (response is DartValue) {
      return new RemoteValue(response);
    } else if (response is InstanceStructure) {
      List<DartValue> fields = new List<DartValue>();
      for (int i = 0; i < response.fields; i++) {
        fields.add(await readNextCommand());
      }
      return new RemoteInstance(response, fields);
    } else if (response is ArrayStructure) {
      List<DartValue> values = new List<DartValue>();
      for (int i = response.startIndex; i < response.endIndex; i++) {
        values.add(await readNextCommand());
      }
      return new RemoteArray(response, values);
    } else {
      return new RemoteErrorObject("Failed reading structured object.");
    }
  }

  Future<List<RemoteObject>> processAllVariables() async {
    assert(isSpawned);
    BackTrace trace = await backTrace();
    ScopeInfo info = trace.scopeInfoForCurrentFrame;
    List<RemoteObject> variables = [];
    for (ScopeInfo current = info;
         current != ScopeInfo.sentinel;
         current = current.previous) {
      variables.add(await processLocal(
          debugState.actualCurrentFrameNumber,
          current.local.slot,
          name: current.name));
    }
    return variables;
  }

  Future<RemoteValue> processLocal(
      int frameNumber,
      int localSlot,
      {String name,
       List<int> fieldAccesses: const <int>[]}) async {
    VmCommand response = await runCommand(
        new ProcessInstance(frameNumber, localSlot, fieldAccesses));
    assert(response is DartValue);
    return new RemoteValue(response, name: name);
  }

  Future<RemoteObject> processLocalStructure(
      int frameNumber,
      int localSlot,
      {String name,
       List<int> fieldAccesses: const <int>[],
       startIndex: 0,
       endIndex: -1}) async {
    frameNumber ??= debugState.actualCurrentFrameNumber;
    await sendCommand(
        new ProcessInstanceStructure(
            frameNumber,
            localSlot, fieldAccesses,
            startIndex,
            endIndex));
    return await readStructuredObject();
  }

  bool toggleInternal() {
    debugState.showInternalFrames = !debugState.showInternalFrames;
    if (debugState.currentBackTrace != null) {
      debugState.currentBackTrace.visibilityChanged();
    }
    return debugState.showInternalFrames;
  }
}
