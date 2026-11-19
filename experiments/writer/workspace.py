"""In-memory experiment tools; no App, real user files or device effects."""
from pathlib import PurePosixPath


def safe_path(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or '..' in path.parts or '\\' in value:
        raise ValueError('Expected a relative workspace path')
    return str(path)


class Workspace:
    def __init__(self, case):
        self.projects = {seed['name']: dict(seed, files=dict(seed['files'])) for seed in case.get('seeds', [])}
        self.original = {name: dict(p['files']) for name, p in self.projects.items()}
        self.selected = case.get('resumeSeed')
        self.commands = []; self.status = 'running'; self.windows = set(); self.case = case
        self.answer = None; self.created = 0; self.rendered = False

    def execute(self, call):
        command = call['command']; self.commands.append(command)
        if command == 'workspace.search':
            query = call.get('query', '').casefold()
            return [dict(name=n,title=p['title'],entry=p['entry']) for n,p in self.projects.items()
                    if query in n.casefold() or query in p['title'].casefold()]
        if command == 'workspace.create':
            name = call['name']
            if name in self.projects:raise ValueError('Workspace already exists')
            self.projects[name] = dict(title=call.get('title',name), entry=call.get('entry',''), files={})
            self.selected = name; self.created += 1
            return dict(name=name)
        if command in ('workspace.open','workspace.select','workspace.delete'):
            name = call['name']
            if name not in self.projects:raise ValueError('Unknown workspace')
            if command == 'workspace.delete':
                del self.projects[name]; self.windows.discard(name)
                if self.selected == name:self.selected = None
            else:
                self.selected = name
                if command == 'workspace.open':self.windows.add(name)
            return dict(completed=True)
        if command == 'ask':
            self.status = 'waiting'
            if self.case.get('answer'):
                self.status = 'running'; return dict(user=self.case['answer'])
            return dict(waiting=True)
        if command == 'finish':
            self.status = 'completed'; self.answer = call.get('text',''); return dict(completed=True)
        if self.selected not in self.projects:raise ValueError('Select or create a workspace first')
        project = self.projects[self.selected]; files = project['files']
        if command == 'list':return sorted(files)
        if command == 'render':
            entry = safe_path(call.get('path', project['entry']))
            if entry not in files:raise ValueError('Missing entry')
            project['entry'] = entry; self.rendered = True
            event = self.case.get('hostEvent')
            if event not in ('hidden','closeOnPreview','minimizeOnPreview'):self.windows.add(self.selected)
            return dict(rendered=entry, synthetic=True, event=event)
        path = safe_path(call['path'])
        if command == 'read':return files[path]
        if command == 'edit':
            content = call['content']
            if not isinstance(content,str) or len(content.encode()) > 2 * 1024 * 1024:raise ValueError('Invalid content size')
            files[path] = content
        elif command == 'replace':
            if not call['old'] or call['old'] not in files[path]:raise ValueError('Replacement text not found')
            files[path] = files[path].replace(call['old'],call['new'])
        elif command == 'remove':del files[path]
        elif command == 'move':files[safe_path(call['destination'])] = files.pop(path)
        else:raise ValueError('Unknown command')
        if self.case.get('hostEvent') == 'cancelAfterContent':self.status = 'cancelled'
        return dict(completed=True)

    def score(self):
        case = self.case; issues = []
        project = self.projects.get(case.get('targetSeed') or self.selected, {})
        files = project.get('files', {})
        for name in case.get('requiredFiles', []):
            if name not in files:issues.append('missingFile:' + name)
        for name in case.get('forbiddenFiles', []):
            if name in files:issues.append('forbiddenFile:' + name)
        for field in ('contains','notContains'):
            for name, values in case.get(field, {}).items():
                for value in values:
                    found = value.casefold() in files.get(name,'').casefold()
                    if found == (field == 'notContains'):issues.append(field + ':' + name + ':' + value)
        original = self.original.get(case.get('targetSeed') or case.get('resumeSeed'), {})
        for name in case.get('unchangedFiles', []):
            if name not in original or files.get(name) != original[name]:issues.append('changedFile:' + name)
        replacement = case.get('exactReplacement')
        if replacement and files.get(replacement['path']) != original.get(replacement['path'],'').replace(replacement['old'],replacement['new']):issues.append('exactReplacement')
        for command in case.get('requiredCommands', []):
            if command not in self.commands:issues.append('missingCommand:' + command)
        for command in case.get('forbiddenCommands', []):
            if command in self.commands:issues.append('forbiddenCommand:' + command)
        if case.get('firstCommand') and (not self.commands or self.commands[0] != case['firstCommand']):issues.append('firstCommand')
        if case.get('noNewWorkspace') and self.created:issues.append('newWorkspace')
        if case.get('deleteSeed') in self.projects:issues.append('workspaceNotDeleted')
        expected_status = 'cancelled' if case.get('expectCancelled') else 'waiting' if case.get('expectWaiting') else 'completed'
        if self.status != expected_status:issues.append('status:' + self.status)
        rule = case.get('windowRule')
        if rule == 'one' and len(self.windows) != 1:issues.append('windowCount')
        if rule in ('none','closed','minimized','deferred') and self.windows:issues.append('windowState')
        if not case.get('library') and not case.get('expectCancelled') and not case.get('expectWaiting') and case['entry'] not in files:issues.append('missingEntry')
        return issues, files
