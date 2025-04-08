module earlytrade::version {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;

    /// Version of the protocol
    public struct Version has key {
        id: UID,
        major: u64,
        minor: u64,
        patch: u64
    }
    
    /// Create initial version and transfer it to the deployer
    fun init(ctx: &mut TxContext) {
        let version = Version {
            id: object::new(ctx),
            major: 1,
            minor: 0,
            patch: 0
        };
        
        transfer::transfer(version, tx_context::sender(ctx));
    }
    
    /// Get current version number
    public fun get_version(version: &Version): (u64, u64, u64) {
        (version.major, version.minor, version.patch)
    }
} 