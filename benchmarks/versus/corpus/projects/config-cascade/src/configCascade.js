/** 配置级联：默认值 < 配置文件 < 环境变量。 */
export function resolveConfig(defaults, fileConfig, envConfig) {
  return { ...defaults, ...envConfig, ...fileConfig };
}
