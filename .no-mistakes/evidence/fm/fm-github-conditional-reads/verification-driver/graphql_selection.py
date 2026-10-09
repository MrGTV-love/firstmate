import re

def response_fields(query):
    tokens=re.findall(r'\.\.\.|[A-Za-z_][A-Za-z_0-9]*|"(?:\\.|[^"\\])*"|[{}():\[\],!@$]|-?\d+',query)
    i=tokens.index('{')
    def group():
        nonlocal i
        assert tokens[i]=='{'; i+=1; fields=[]
        while tokens[i]!='}':
            if tokens[i]==',': i+=1; continue
            if tokens[i]=='...':
                i+=3; fields.extend(group()); continue
            alias=name=tokens[i]; i+=1
            if tokens[i]==':': name=tokens[i+1]; i+=2
            if tokens[i]=='(':
                depth=1; i+=1
                while depth:
                    if tokens[i]=='(': depth+=1
                    if tokens[i]==')': depth-=1
                    i+=1
            nested=group() if tokens[i]=='{' else None
            fields.append((alias,name,nested))
        i+=1; return fields
    return group()

def project(value,fields):
    if isinstance(value,list): return [project(v,fields) for v in value]
    if value is None: return None
    return {alias:project(value.get(name),nested) if nested else value.get(name) for alias,name,nested in fields}
