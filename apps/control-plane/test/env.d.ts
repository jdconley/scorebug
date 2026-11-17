// The Node tests read response bodies as loose JSON, as the Worker tests do with `body()`.
declare global {
  interface Response {
    json(): Promise<any>;
  }
}
export {};
