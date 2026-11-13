// The entry point owns resources; World never stores GPU objects.
Services :: struct { batcher: *F.Batcher; }
services_init :: (services: *Services) { services.batcher = F.batcher_create(F.App.device); }
services_dispose :: (services: *Services) {
    if services.batcher != null { F.batcher_destroy(services.batcher); services.batcher = null; }
}
