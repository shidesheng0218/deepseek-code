export function loadPermissionRules(projectPath: string): Promise<string[]>;
export function addPermissionRule(projectPath: string, tool: string): Promise<number>;
export function removePermissionRule(projectPath: string, tool: string): Promise<number>;
export function isAllowedByRule(rules: string[], tool: string): boolean;
