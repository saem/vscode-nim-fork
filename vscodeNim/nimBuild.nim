import vscodeApi
import tsNimExtApi
import jsNode
import jsNodeCp
import jsffi
import jsPromise
import jsNodeOs
import jsString
import jsre
import jsconsole

type CheckResult = ref object
    file:cstring
    line:cint
    column:cint
    msg:cstring
    severity:cstring

type ExecutorStatus = ref object
    initialized:bool
    process:ChildProcess

var executors = newJsAssoc[cstring, ExecutorStatus]()

proc nimExec(
        project:ProjectFileInfo,
        cmd:cstring,
        args:seq[cstring],
        useStdErr:bool,
        cb:(proc(lines:seq[cstring]):seq[CheckResult])
    ):Promise[seq[CheckResult]] =
        return newPromise(proc(
            resolve:proc(results:seq[CheckResult]),
            reject:proc(reason:JsObject)
        ) =
            var execPath = nimUtils.getNimExecPath()
            if execPath.isNull() or execPath.isUndefined():
                resolve(@[])
                return

            var projectPath = nimUtils.toLocalFile(project)
            var executorStatus = executors[projectPath]
            if(not executorStatus.isNil() and executorStatus.initialized):
                var ps = executorStatus.process
                executors[projectPath] = ExecutorStatus{
                    initialized: false, process: jsUndefined.to(ChildProcess)
                }
                if not ps.isNil():
                    ps.kill("SIGKILL")
            else:
                executors[projectPath] = ExecutorStatus{
                    initialized: false, process: jsUndefined.to(ChildProcess)
                }
            
            var executor = cp.spawn(
                    nimUtils.getNimExecPath(),
                    @[cmd] & args,
                    SpawnOptions{ cwd: project.wsFolder.uri.fsPath }
                )
            executors[projectPath].process = executor
            executors[projectPath].initialized = true

            executor.onError(proc(error:ChildError):void =
                if not error.isNil() and error.code == "ENOENT":
                    vscode.window.showInformationMessage(
                        "No nim binary could be found in PATH: '" & process.env["PATH"] & "'"
                    )
                    resolve(@[])
                    return
            )

            executor.stdout.onData(proc(data:Buffer) =
                nimUtils.outputLine("[info] nim check output:\n" & data.toString())
            )

            var output:cstring = ""
            executor.onExit(proc(code:cint, signal:cstring) =
                if signal == "SIGKILL":
                    reject([].toJs())
                else:
                    executors[projectPath] = ExecutorStatus{
                        initialized: false,
                        process: jsUndefined.to(ChildProcess)
                    }

                    try:
                        var split:seq[cstring] = output.split(nodeOs.eol)
                        if split.len == 1:
                            # TODO - is this a bug by not using os.eol??
                            var lfSplit = split[0].split("\n")
                            if  lfSplit.len > split.len:
                                split = lfSplit

                        resolve(cb(split))
                    except:
                        reject(getCurrentException().toJs())
            )

            if useStdErr:
                executor.stderr.onData(proc(data:Buffer) =
                        output &= data.toString()
                    )
            else:
                executor.stdout.onData(proc(data:Buffer) =
                        output &= data.toString()
                    )
        )

proc parseErrors(lines:seq[cstring]):seq[CheckResult] =
    var ret:seq[CheckResult] = @[]
    var messageText = ""
    var lastFile:cstring = ""
    var lastColumn:cstring = ""
    var lastLine:cstring = ""

    for l in lines:
        var line:cstring = l.strip()
        if line.startsWith("Hint:"):
            continue

        var match = newRegExp(r"^([^(]*)?\((\d+)(,\s(\d+))?\)( (\w+):)? (.*)").exec(line)
        if not match.isNull():
            if messageText.len < 1024:
                messageText &= nodeOs.eol & line
        else:
            var file = match[1]
            var lineStr = match[2]
            var charStr = match[4]
            var severity = match[6]
            var msg = match[7]

            if msg == "template/generic instantiation from here":
                if nimUtils.isWorkspaceFile(file):
                    lastFile = file
                    lastColumn = charStr
                    lastLine = lineStr
            else:
                if messageText.len > 0 and ret.len > 0:
                    ret[ret.len - 1].msg &= nodeOs.eol & messageText
                
                messageText = ""
                if nimUtils.isWorkspaceFile(file):
                    ret.add(CheckResult{
                        file: file,
                        line:lineStr.parseCint(),
                        column:charStr.parseCint(),
                        msg:msg,
                        severity:severity
                    })
                elif lastFile.len > 0:
                    ret.add(CheckResult{
                        file:lastFile,
                        line:lastLine.parseCint(),
                        column:lastColumn.parseCint(),
                        msg:msg,
                        severity:severity
                    })
                lastFile = ""
                lastColumn = ""
                lastLine = ""
    if messageText.len > 0 and ret.len > 0:
        ret[ret.len - 1].msg &= nodeOs.eol & messageText
    
    return ret

proc parseNimsuggestErrors(items:seq[NimSuggestResult]):seq[CheckResult] =
    var ret:seq[CheckResult] = @[]
    for item in items:
        if item.path == "???" and item.`type` == "Hint":
            continue
        ret.add(CheckResult{
            file:item.path,
            line:item.line,
            column:item.column,
            msg:item.documentation,
            severity:item.`type`
        })
    return ret

proc check*(filename:cstring, nimConfig:VscodeWorkspaceConfiguration):Promise[seq[CheckResult]] =
    var runningToolsPromises:seq[Promise[seq[CheckResult]]] = @[]

    console.log("check", jsArguments)
    if nimConfig["useNimsuggestCheck"].isNil() or nimConfig["useNimsuggestCheck"].to(bool):
        runningToolsPromises.add(newPromise(proc(
                resolve:proc(values:seq[CheckResult]),
                reject:proc(reason:JsObject)
            ) = nimSuggestExec.execNimSuggest(NimSuggestType.chk, filename, 0, 0, "").then(
                    proc(items:seq[NimSuggestResult]) =
                        console.log("check - execNimSuggest", jsArguments)
                        if not items.isNull() and items.len > 0:
                            resolve(parseNimsuggestErrors(items))
                        else:
                            resolve(@[])
                ).catch(proc(reason:JsObject) = reject(reason))
            )
        )
    else:
        if not nimUtils.isProjectMode():
            var project = nimUtils.getProjectFileInfo(filename)
            runningToolsPromises.add(nimExec(
                project, 
                "check",
                @["--listFullPaths".cstring, project.filePath],
                true,
                parseErrors
            ))
        else:
            for project in nimUtils.getProjects():
                runningToolsPromises.add(nimExec(
                    project, 
                    "check",
                    @["--listFullPaths".cstring, project.filePath],
                    true,
                    parseErrors
                ))

    return all(runningToolsPromises).then(proc(resultSets:seq[seq[CheckResult]]):seq[CheckResult] =
            console.log("check - all", jsArguments)
            var ret:seq[CheckResult] = @[]
            for rs in resultSets:
                ret.add(rs)
            return ret
        )

var evalTerminal:VscodeTerminal

proc activateEvalConsole*():void =
    vscode.window.onDidCloseTerminal(proc(e:VscodeTerminal) =
        if not evalTerminal.isNil() and e.processId == evalTerminal.processId:
            evalTerminal = jsUndefined.to(VscodeTerminal)
    )

proc execSelectionInTerminal*(doc:VscodeTextDocument):void =
    if not vscode.window.activeTextEditor.isNil():
        if nimUtils.getNimExecPath().isNil():
            return

        if evalTerminal.isNil():
            evalTerminal = vscode.window.createTerminal("Nim Console")
            evalTerminal.show(true)
            evalTerminal.sendText(nimUtils.getNimExecPath() & " secret\n")

        evalTerminal.sendText(
            vscode.window.activeTextEditor.document.getText(vscode.window.activeTextEditor.selection))