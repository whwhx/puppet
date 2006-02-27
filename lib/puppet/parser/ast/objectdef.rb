class Puppet::Parser::AST
    # Any normal puppet object declaration.  Can result in a class or a 
    # component, in addition to builtin types.
    class ObjectDef < AST::Branch
        attr_accessor :name, :type
        attr_reader :params

        # probably not used at all
        def []=(index,obj)
            @params[index] = obj
        end

        # probably not used at all
        def [](index)
            return @params[index]
        end

        # Auto-generate a name
        def autoname(type, object)
            case object
            when Puppet::Type:
                raise Puppet::Error,
                    "Built-in types must be provided with a name"
            when Node:
                return type
            else
                Puppet.debug "Autogenerating name for object of type %s" %
                    type
                return [type, "-", self.object_id].join("")
            end
        end

        # Iterate across all of our children.
        def each
            [@type,@name,@params].flatten.each { |param|
                #Puppet.debug("yielding param %s" % param)
                yield param
            }
        end

        # Does not actually return an object; instead sets an object
        # in the current scope.
        def evaluate(hash)
            scope = hash[:scope]
            @scope = scope
            hash = {}

            # Get our type and name.
            objtype = @type.safeevaluate(:scope => scope)

            # If the type was a variable, we wouldn't have typechecked yet.
            # Do it now, if so.
            unless @checked
                self.typecheck(objtype)
            end

            # See if our object type was defined.  If not, we know it's
            # builtin because we already typechecked.
            begin
                object = scope.lookuptype(objtype)
            rescue Puppet::ParseError => except
                except.line = self.line
                except.file = self.file
                raise except
            rescue => detail
                error = Puppet::ParseError.new(detail)
                error.line = self.line
                error.file = self.file
                error.backtrace = detail.backtrace
                raise error
            end

            autonamed = false
            objnames = [nil]
            # Autogenerate the name if one was not passed.
            if self.name
                objnames = @name.safeevaluate(:scope => scope)
                # it's easier to always use an array, even for only one name
                unless objnames.is_a?(Array)
                    objnames = [objnames]
                end
            #else
            #    objnames = self.autoname(objtype, object)
            #    autonamed = true

            end

            # Retrieve the defaults for our type
            hash = getdefaults(objtype, scope)

            # then set all of the specified params
            @params.each { |param|
                ary = param.safeevaluate(:scope => scope)
                hash[ary[0]] = ary[1]
            }

            # this is where our implicit iteration takes place;
            # if someone passed an array as the name, then we act
            # just like the called us many times
            objnames.collect { |objname|
                # If the object is a class, that means it's a builtin type, so
                # we just store it in the scope
                unless object
                    unless objname
                        raise Puppet::ParseError,
                            "Object of type %s created with no name" % objtype
                    end

                    begin
                        #Puppet.debug(
                        #    ("Setting object '%s' " +
                        #    "in scope %s " +
                        #    "with arguments %s") %
                        #    [objname, scope.object_id, hash.inspect]
                        #)
                        obj = scope.setobject(
                            :type => objtype,
                            :name => objname,
                            :arguments => hash,
                            :file => @file,
                            :line => @line
                        )
                    rescue Puppet::ParseError => except
                        except.line = self.line
                        except.file = self.file
                        raise except
                    rescue => detail
                        error = Puppet::ParseError.new(detail)
                        error.line = self.line
                        error.file = self.file
                        error.backtrace = detail.backtrace
                        raise error
                    end
                else
                    # but things like components create a new type; if we find
                    # one of those, evaluate that with our arguments
                    #Puppet.debug("Calling object '%s' with arguments %s" %
                    #    [object.name, hash.inspect])
                    #obj = object.safeevaluate(scope,hash,objtype,objname)
                    obj = object.safeevaluate(
                        :scope => scope,
                        :arguments => hash,
                        :type => objtype,
                        :name => objname
                    )

                    # Retain any name generation stuff
                    obj.autoname = autonamed

                    # and pass the result on
                    obj
                end
            }.reject { |obj| obj.nil? }
        end

        # Retrieve the defaults for our type
        def getdefaults(objtype, scope)
            # first, retrieve the defaults
            begin
                defaults = scope.lookupdefaults(objtype)
                if defaults.length > 0
                    #Puppet.debug "Got defaults for %s: %s" %
                    #    [objtype,defaults.inspect]
                end
            rescue => detail
                raise Puppet::DevError, 
                    "Could not lookup defaults for %s: %s" %
                        [objtype, detail.to_s]
            end

            hash = {}
            # Add any found defaults to our argument list
            defaults.each { |var,value|
                Puppet.debug "Found default %s for %s" %
                    [var,objtype]

                hash[var] = value
            }

            return hash
        end

        # Create our ObjectDef.  Handles type checking for us.
        def initialize(hash)
            @checked = false
            super

            self.typecheck(@type.value)
        end

        # Verify that all passed parameters are valid
        def paramcheck(builtin, objtype)
            # This defaults to true
            unless Puppet[:paramcheck]
                return
            end

            @params.each { |param|
                if builtin
                    self.parambuiltincheck(builtin, param)
                else
                    self.paramdefinedcheck(objtype, param)
                end
            }

            # Mark that we've made it all the way through.
            @checked = true
        end

        def parambuiltincheck(type, param)
            unless param.is_a?(AST::ObjectParam)
                raise Puppet::DevError,
                    "Got something other than param"
            end
            begin
                pname = param.param.value
            rescue => detail
                raise Puppet::DevError, detail.to_s
            end
            return if pname == "name" # always allow these
            unless type.validattr?(pname)
                error = Puppet::ParseError.new(
                    "Invalid parameter '%s' for type '%s'" %
                        [pname,type.name]
                )
                error.line = self.line
                error.file = self.file
                raise error
            end
        end

        def paramdefinedcheck(objtype, param)
            # FIXME We might need to do more here eventually.  Metaparams
            # behave strangely on containers.
            if Puppet::Type.metaparam?(param.param.value.intern)
                return
            end

            begin
                pname = param.param.value
            rescue => detail
                raise Puppet::DevError, detail.to_s
            end

            # FIXME This should look through the scope tree, not in a global
            # hash
            unless objtype.validarg?(pname)
                error = Puppet::ParseError.new(
                    "Invalid parameter '%s' for type '%s'" %
                        [pname,objtype]
                )
                error.line = self.line
                error.file = self.file
                raise error
            end
        end

        # Set the parameters for our object.
        def params=(params)
            if params.is_a?(AST::ASTArray)
                @params = params
            else
                @params = AST::ASTArray.new(
                    :line => params.line,
                    :file => params.file,
                    :children => [params]
                )
            end
        end

        # Print this object out.
        def tree(indent = 0)
            return [
                @type.tree(indent + 1),
                @name.tree(indent + 1),
                ((@@indline * indent) + self.typewrap(self.pin)),
                @params.collect { |param|
                    begin
                        param.tree(indent + 1)
                    rescue NoMethodError => detail
                        Puppet.err @params.inspect
                        error = Puppet::DevError.new(
                            "failed to tree a %s" % self.class
                        )
                        error.backtrace = detail.backtrace
                        raise error
                    end
                }.join("\n")
            ].join("\n")
        end

        # Verify that the type is valid.  This throws an error if there's
        # a problem, so the return value doesn't matter
        def typecheck(objtype)
            # This will basically always be on, but I wanted to make it at
            # least simple to turn off if it came to that
            unless Puppet[:typecheck]
                return
            end

            builtin = false
            begin
                builtin = Puppet::Type.type(objtype)
            rescue TypeError
                # nothing; we've already set builtin to false
            end

            typeobj = nil
            if builtin
                self.paramcheck(builtin, objtype)
            else
                # If there's no set scope, then we're in initialize, not
                # evaluate, so we can't test defined types.
                return true unless defined? @scope and @scope

                # Unless we can look up the type, throw an error
                unless objtype = @scope.lookuptype(objtype)
                    error = Puppet::ParseError.new(
                        "Unknown type '%s'" % objtype
                    )
                    error.line = self.line
                    error.file = self.file
                    raise error
                end

                # Now that we have the type, verify all of the parameters.
                # Note that we're now passing an AST Class object or whatever
                # as the type, not a simple string.
                self.paramcheck(builtin, objtype)
            end
        end

        def to_s
            return "%s => { %s }" % [@name,
                @params.collect { |param|
                    param.to_s
                }.join("\n")
            ]
        end
    end
end
